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
    let runID = try runningBoundRun()
    try freezeSurface(runID: runID, skillSetDigest: skillSetDigest)
    _ = try runs.commitAssistantTurn(assistantTurn(runID: runID), now: now)
    return runID
  }

  /// A historical terminal receipt whose last provider usage or lane finalizer is still owed.
  func terminalBoundRunWithoutSettlement() throws -> Int64 {
    let runID = try runningBoundRun()
    try seedDeferredCancellation(runID: runID)
    return runID
  }

  /// Seeds a persisted interruption so readers and crash recovery can consume an unsettled receipt.
  func seedDeferredCancellation(runID: Int64) throws {
    try queue.write { db in
      _ = try RunStoreGRDB.transitionRun(
        db,
        runID: runID,
        event: .cancel,
        now: now,
        terminal: .deferred(.ownerCancelled)
      )
    }
  }

  func freezeSurface(runID: Int64, skillSetDigest: String) throws {
    try learning.freezeCompatibility(
      runID: runID,
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
  func proposeUnansweredToolCall(runID: Int64) throws {
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_calls)
          VALUES (?, ?, 'assistant', '', 'trusted', ?,
            '[{"id":"c1","name":"file_read","arguments":"{}"},
              {"id":"c2","name":"file_write","arguments":"{}"}]')
          """,
        arguments: [sessionID, runID, now]
      )
      try db.execute(
        sql: """
          INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_call_id)
          VALUES (?, ?, 'tool', 'ok', 'untrusted', ?, 'c1')
          """,
        arguments: [sessionID, runID, now]
      )
    }
  }

  /// An earlier round's usage row, written straight to the table: the fallback shape is a run whose
  /// first attempt billed one route and whose answering round billed another.
  func recordEarlierUsage(runID: Int64, model: String) throws {
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO provider_usage(provider_call_id, run_id, session_id, model, prompt_tokens,
            completion_tokens, cost_usd, cost_source, is_estimated, ts)
          VALUES (?, ?, ?, ?, 1, 1, 0.0, ?, 0, ?)
          """,
        arguments: [UUID().uuidString, runID, sessionID, model, CostSource.heuristic.rawValue, now]
      )
    }
  }

  func terminalRoute(runID: Int64) throws -> String? {
    try queue.read { db in
      try String.fetchOne(
        db,
        sql: "SELECT terminal_route FROM run_settlements WHERE run_id = ?",
        arguments: [runID]
      )
    }
  }

  func advanceJobEpoch() throws {
    try queue.write { db in
      try db.execute(
        sql: "UPDATE job_learning_state SET learning_epoch = learning_epoch + 1 WHERE job_id = ?",
        arguments: [jobID]
      )
    }
  }

  func evidenceCount(runID: Int64) throws -> Int {
    try queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM learning_evidence WHERE run_id = ?",
        arguments: [runID]
      ) ?? -1
    }
  }
}
