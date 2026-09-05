import ClawCore
import Foundation
import GRDB

extension ScheduledLearningStoreGRDB {
  public func sweepRetention(now: Date) throws(StoreError) -> RetentionSweepResult {
    try database.writeMapping { db in
      let snapshot = try LearningRetentionSnapshot(db)
      let payloadCutoff = EpochSecondCodec.epoch(now.addingTimeInterval(-EvidenceWindow.maximumAge))
      let receiptCutoff = EpochSecondCodec.epoch(now.addingTimeInterval(-Self.receiptRetention))
      var live = try snapshot.liveReferences(db, now: now)
      try snapshot.expand(&live)
      var compact = live
      snapshot.retainRecent(&compact, cutoff: receiptCutoff)
      try snapshot.retainResetBarrier(&compact)
      try snapshot.expand(&compact)
      try snapshot.retainClosedReplacements(db, &compact)
      let payloads = try snapshot.clearPayloads(db, excluding: live, cutoff: payloadCutoff)
      let receipts = try snapshot.collectReceipts(db, excluding: compact, cutoff: receiptCutoff)
      return RetentionSweepResult(deletedPayloads: payloads, deletedReceipts: receipts)
    }
  }

  private static let receiptRetention: TimeInterval = 90 * 86_400
}

struct LearningRetentionReferences: Equatable {
  var runs: Set<Int64> = []
  var candidates: Set<String> = []
  var trials: Set<Int64> = []
  var decisions: Set<Int64> = []
  var operations: Set<String> = []
  var feedback: Set<Int64> = []
  var challenges: Set<Int64> = []
  var lessons: Set<LearningRetentionLesson> = []
}

struct LearningRetentionLesson: Hashable {
  let jobId: Int64
  let digest: String
}

struct LearningRetentionSnapshot {
  let states: [Row]
  let bindings: [Row]
  let settlements: [Row]
  let evidence: [Row]
  let evaluations: [Row]
  let candidates: [Row]
  let trials: [Row]
  let assignments: [Row]
  let decisions: [Row]
  let operations: [Row]
  let feedback: [Row]
  let targets: [Row]
  let challenges: [Row]
  let lessons: [Row]

  init(_ db: Database) throws {
    states = try Row.fetchAll(db, sql: "SELECT * FROM job_learning_state")
    bindings = try Row.fetchAll(db, sql: "SELECT * FROM run_learning_bindings")
    settlements = try Row.fetchAll(db, sql: "SELECT * FROM run_settlements")
    evidence = try Row.fetchAll(db, sql: "SELECT * FROM learning_evidence")
    evaluations = try Row.fetchAll(db, sql: "SELECT * FROM learning_evaluations")
    candidates = try Row.fetchAll(db, sql: "SELECT * FROM learning_candidates")
    trials = try Row.fetchAll(db, sql: "SELECT * FROM learning_trials")
    assignments = try Row.fetchAll(db, sql: "SELECT * FROM trial_assignments")
    decisions = try Row.fetchAll(db, sql: "SELECT * FROM learning_decisions")
    operations = try Row.fetchAll(db, sql: "SELECT * FROM learning_operations")
    feedback = try Row.fetchAll(db, sql: "SELECT * FROM feedback_events")
    targets = try Row.fetchAll(db, sql: "SELECT * FROM feedback_targets")
    challenges = try Row.fetchAll(db, sql: "SELECT * FROM feedback_challenges")
    lessons = try Row.fetchAll(db, sql: "SELECT * FROM lesson_sets")
  }
}

// MARK: - Collection

extension LearningRetentionSnapshot {
  func clearPayloads(
    _ db: Database,
    excluding retained: LearningRetentionReferences,
    cutoff: Int64
  ) throws -> Int {
    var count = 0
    for row in evidence where !retained.runs.contains(row["run_id"]) {
      guard (row["sealed_at"] as Int64) < cutoff, (row["payload"] as Data?) != nil else {
        continue
      }
      try db.execute(
        sql: "UPDATE learning_evidence SET payload = NULL WHERE run_id = ?",
        arguments: [row["run_id"] as Int64]
      )
      count += db.changesCount
    }
    for row in feedback where !retained.feedback.contains(row["event_id"]) {
      guard (row["occurred_at"] as Int64) < cutoff, (row["payload"] as String?) != nil else {
        continue
      }
      try db.execute(
        sql: "UPDATE feedback_events SET payload = NULL WHERE event_id = ?",
        arguments: [row["event_id"] as Int64]
      )
      count += db.changesCount
    }
    return count
  }

  func collectReceipts(
    _ db: Database,
    excluding retained: LearningRetentionReferences,
    cutoff: Int64
  ) throws -> Int {
    let before = db.totalChangesCount
    // Supersession edges are self-references; all unreachable members leave in this transaction.
    try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
    for row in decisions where !retained.decisions.contains(row["decision_id"]) {
      try delete(db, table: "learning_decisions", key: "decision_id", row: row)
    }
    for row in feedback where !retained.feedback.contains(row["event_id"]) {
      try delete(db, table: "feedback_events", key: "event_id", row: row)
    }
    for row in operations where !retained.operations.contains(row["operation_id"]) {
      try delete(db, table: "learning_operations", key: "operation_id", row: row)
    }
    for row in assignments where !retained.runs.contains(row["run_id"]) {
      try delete(db, table: "trial_assignments", key: "run_id", row: row)
    }
    for row in trials where !retained.trials.contains(row["trial_id"]) {
      try delete(db, table: "learning_trials", key: "trial_id", row: row)
    }
    for row in candidates where !retained.candidates.contains(row["candidate_digest"]) {
      try delete(db, table: "learning_candidates", key: "candidate_digest", row: row)
    }
    for row in bindings where !retained.runs.contains(row["run_id"]) {
      for table in [
        "learning_evaluations", "learning_evidence", "run_compatibility", "run_settlements",
        "run_learning_bindings",
      ] {
        try delete(db, table: table, key: "run_id", row: row)
      }
    }
    for row in targets where (row["expires_at"] as Int64) < cutoff {
      guard !subjectIsRetained(row, retained: retained) else {
        continue
      }
      try delete(db, table: "feedback_targets", key: "target_id", row: row)
    }
    for row in challenges where !retained.challenges.contains(row["challenge_id"]) {
      try delete(db, table: "feedback_challenges", key: "challenge_id", row: row)
    }
    for row in lessons where (row["created_at"] as Int64) < cutoff {
      let lesson = LearningRetentionLesson(jobId: row["job_id"], digest: row["digest"])
      guard !retained.lessons.contains(lesson) else {
        continue
      }
      try db.execute(
        sql: "DELETE FROM lesson_sets WHERE job_id = ? AND digest = ?",
        arguments: [lesson.jobId, lesson.digest]
      )
    }
    return db.totalChangesCount - before
  }
}

// MARK: - Row Identity

private extension LearningRetentionSnapshot {
  func delete(_ db: Database, table: String, key: String, row: Row) throws {
    let value: DatabaseValue = row[key]
    try db.execute(sql: "DELETE FROM \(table) WHERE \(key) = ?", arguments: [value])
  }
}
