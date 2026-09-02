import ClawCore
import Foundation
import GRDB

@testable import ClawData

/// The sealing suite's shapes: a bound run whose evidence is frozen, one whose settlement is still
/// deferred, and the pickup-time surface freeze the sealer must read back instead of recomputing.
extension BoundRunEnvironment {
  static let pickupSkillSetDigest = "skills-as-of-pickup"
  static let laterSkillSetDigest = "skills-after-the-owner-installed-one"

  /// A bound run picked up, frozen against `skillSetDigest`, then completed — so `settled_at` is
  /// written by the commit that won the state, exactly as an ordinary DONE turn does it.
  func settledBoundRun(
    skillSetDigest: String = BoundRunEnvironment.pickupSkillSetDigest
  ) throws -> Int64 {
    let runId = try runningBoundRun()
    try freezeSurface(runId: runId, skillSetDigest: skillSetDigest)
    _ = try runs.commitAssistantTurn(assistantTurn(runId: runId), now: now)
    return runId
  }

  /// A bound run that is terminal with its settlement still deferred — the shape `/stop` leaves
  /// while the in-flight round's usage can still land against the run.
  func terminalBoundRunWithoutSettlement() throws -> Int64 {
    let runId = try runningBoundRun()
    _ = try runs.cancelActiveRun(sessionId: sessionId, reason: .cancelled, now: now)
    return runId
  }

  func freezeSurface(runId: Int64, skillSetDigest: String) throws {
    try learning.freezeCompatibility(
      runId: runId,
      surface: RunSurface(
        toolCatalogDigest: "tools-v1",
        policyVersion: "pv16",
        skillSetDigest: skillSetDigest,
        configuredRoute: "openai-compatible/test-model"
      )
    )
  }

  /// Anchors two proposed calls with only one observation answering them — the incomplete shape a
  /// crash between a tool dispatch and its result row leaves in the message log.
  func proposeUnansweredToolCall(runId: Int64) throws {
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_calls)
          VALUES (?, ?, 'assistant', '', 'trusted', ?,
            '[{"id":"c1","name":"file_read","arguments":"{}"},
              {"id":"c2","name":"file_write","arguments":"{}"}]')
          """,
        arguments: [sessionId, runId, now]
      )
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_call_id)
          VALUES (?, ?, 'tool', 'ok', 'untrusted', ?, 'c1')
          """,
        arguments: [sessionId, runId, now]
      )
    }
  }

  func advanceJobEpoch() throws {
    try queue.write { db in
      try db.execute(
        sql: "UPDATE job_learning_state SET learning_epoch = learning_epoch + 1 WHERE job_id = ?",
        arguments: [jobId]
      )
    }
  }

  func evidenceCount(runId: Int64) throws -> Int {
    try queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM learning_evidence WHERE run_id = ?",
        arguments: [runId]
      ) ?? -1
    }
  }
}
