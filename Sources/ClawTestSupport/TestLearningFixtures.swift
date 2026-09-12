import ClawCore
import ClawData
import Foundation
import GRDB

/// Seeds learning prerequisites without creating unrelated runs, trials or owner deliveries.
/// Behavior tests use the owning production transaction after arranging these rows.
public struct TestLearningFixtures {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  @discardableResult
  public func seedArmedJob(jobId: Int64, now: Date) throws(StoreError) -> JobLearningState {
    do {
      return try writer.write { db in
        let empty = LessonSet.empty(jobId: jobId)
        try db.execute(
          sql: """
            INSERT OR IGNORE INTO lesson_sets(
              job_id, digest, schema_version, canonical_bytes, source, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            jobId, empty.digest.rawValue, empty.schemaVersion, empty.canonicalBytes,
            LessonSetSource.canonicalEmpty.rawValue, Int64(now.timeIntervalSince1970),
          ]
        )
        try db.execute(
          sql: """
            INSERT OR IGNORE INTO job_learning_state(
              job_id, learning_epoch, stable_lesson_set_digest, stable_revision,
              open_trial_id, feedback_revision, armed_at)
            VALUES (?, 1, ?, 0, NULL, 0, ?)
            """,
          arguments: [jobId, empty.digest.rawValue, Int64(now.timeIntervalSince1970)]
        )
        guard
          let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM job_learning_state WHERE job_id = ?",
            arguments: [jobId]
          )
        else {
          throw StoreError.unexpected("learning fixture state is missing")
        }
        return JobLearningState(
          jobId: jobId,
          epoch: LearningEpoch(row["learning_epoch"]),
          stableDigest: LessonSetDigest(rawValue: row["stable_lesson_set_digest"]),
          stableRevision: StableRevision(row["stable_revision"]),
          openTrialId: row["open_trial_id"],
          feedbackRevision: FeedbackRevision(row["feedback_revision"])
        )
      }
    } catch {
      throw ClawDatabase.classifyError(error)
    }
  }

  public func seedTargets(_ targets: [NewFeedbackTarget]) throws(StoreError) {
    do {
      try writer.write { db in
        for target in targets {
          let actions = try JSONEncoder().encode(target.allowedActions.map(\.rawValue))
          try db.execute(
            sql: """
              INSERT INTO feedback_targets(
                nonce, job_id, learning_epoch, subject_kind, subject_digest, allowed_actions,
                owner_user_id, chat_id, expires_at, consumed_at)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
              """,
            arguments: [
              target.nonce, target.jobId, target.epoch.value, target.subjectKind.rawValue,
              target.subjectDigest, String(bytes: actions, encoding: .utf8), target.ownerUserId,
              target.chatId, Int64(target.expiresAt.timeIntervalSince1970),
            ]
          )
        }
      }
    } catch {
      throw ClawDatabase.classifyError(error)
    }
  }

  /// Reads the durable receipt after a production run transition or lane settlement.
  public func settlement(runId: Int64) throws(StoreError) -> RunSettlement? {
    do {
      return try writer.read { db -> RunSettlement? in
        guard
          let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM run_settlements WHERE run_id = ?",
            arguments: [runId]
          )
        else {
          return nil
        }
        guard let state = RunState(rawValue: row["winning_state"]),
          let cause = TerminalCause(rawValue: row["terminal_cause"])
        else {
          throw StoreError.unexpected("learning fixture receipt is unreadable")
        }
        let terminalEpoch: Int64 = row["terminal_at"]
        let settledEpoch: Int64? = row["settled_at"]
        return RunSettlement(
          runId: runId,
          winningState: state,
          terminalCause: cause,
          terminalAt: Date(timeIntervalSince1970: Double(terminalEpoch)),
          settledAt: settledEpoch.map { epoch in
            Date(timeIntervalSince1970: Double(epoch))
          }
        )
      }
    } catch {
      throw ClawDatabase.classifyError(error)
    }
  }
}
