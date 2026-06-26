import ClawCore
import Foundation
import GRDB

public struct CommandStoreGRDB: CommandStore {
  private let writer: any DatabaseWriter
  private let afterClaimForTesting: @Sendable () throws -> Void

  public init(writer: any DatabaseWriter) {
    self.init(writer: writer, afterClaimForTesting: {})
  }

  init(
    writer: any DatabaseWriter,
    afterClaimForTesting: @Sendable @escaping () throws -> Void
  ) {
    self.writer = writer
    self.afterClaimForTesting = afterClaimForTesting
  }

  public func applyStop(
    updateId: Int64,
    sessionKey: String,
    now: Date
  ) throws -> StopCommandResult {
    try writer.writeMapping { db in
      let newlyClaimed = try ProcessedUpdateStoreGRDB.claimUpdate(
        db: db,
        updateId: updateId,
        claimedAt: now
      )
      guard newlyClaimed else {
        return StopCommandResult(newlyClaimed: false, sessionId: nil, cancelledRunId: nil)
      }

      try afterClaimForTesting()

      let sessionId = try SessionMessageStoreGRDB.upsertSession(
        db,
        sessionKey: sessionKey,
        now: now
      )
      let runId = try Int64.fetchOne(
        db,
        sql: """
          SELECT id FROM runs
          WHERE session_id = ? AND state = ?
          ORDER BY id DESC
          LIMIT 1
          """,
        arguments: [sessionId, RunState.running.rawValue]
      )
      let cancelledRunId: Int64?
      if let runId, try Self.transitionRun(db, runId: runId, event: .cancel, now: now) != nil {
        cancelledRunId = runId
      } else {
        cancelledRunId = nil
      }

      try AuditLogGRDB.insertAudit(
        db,
        AuditEvent(
          actor: .owner,
          action: .turnCancelled,
          argsRedacted: "/stop",
          decision: cancelledRunId == nil ? "nothing_to_stop" : "cancelled",
          runId: cancelledRunId,
          sessionId: sessionId,
          ts: now
        )
      )

      return StopCommandResult(
        newlyClaimed: true,
        sessionId: sessionId,
        cancelledRunId: cancelledRunId
      )
    }
  }

  public func applyNew(
    updateId: Int64,
    sessionKey: String,
    now: Date
  ) throws -> NewCommandResult {
    try writer.writeMapping { db in
      let newlyClaimed = try ProcessedUpdateStoreGRDB.claimUpdate(
        db: db,
        updateId: updateId,
        claimedAt: now
      )
      guard newlyClaimed else {
        return NewCommandResult(newlyClaimed: false, sessionId: nil, supersededRunIds: [])
      }

      try afterClaimForTesting()

      let sessionId = try SessionMessageStoreGRDB.upsertSession(
        db,
        sessionKey: sessionKey,
        now: now
      )
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT id FROM runs
          WHERE session_id = ? AND state IN (?, ?)
          ORDER BY id ASC
          """,
        arguments: [sessionId, RunState.pending.rawValue, RunState.running.rawValue]
      )

      var supersededRunIds: [Int64] = []
      for row in rows {
        let runId: Int64 = row["id"]
        if try Self.transitionRun(db, runId: runId, event: .supersede, now: now) != nil {
          supersededRunIds.append(runId)
        }
      }

      try Self.resetWindowAndDetaint(db, sessionId: sessionId, now: now)
      try Self.insertNewAudits(db, sessionId: sessionId, runIds: supersededRunIds, now: now)

      return NewCommandResult(
        newlyClaimed: true,
        sessionId: sessionId,
        supersededRunIds: supersededRunIds
      )
    }
  }

  private static func resetWindowAndDetaint(_ db: Database, sessionId: Int64, now: Date) throws {
    try db.execute(
      sql: """
        UPDATE sessions
        SET window_start_message_id = (
          SELECT COALESCE(MAX(messages.id), 0) FROM messages WHERE messages.session_id = ?
        ),
        tainted = 0,
        updated_ts = ?
        WHERE id = ?
        """,
      arguments: [sessionId, now, sessionId]
    )
  }

  private static func insertNewAudits(
    _ db: Database,
    sessionId: Int64,
    runIds: [Int64],
    now: Date
  ) throws {
    guard !runIds.isEmpty else {
      try AuditLogGRDB.insertAudit(
        db,
        AuditEvent(
          actor: .owner,
          action: .turnSuperseded,
          argsRedacted: "/new",
          decision: "fresh_window",
          sessionId: sessionId,
          ts: now
        )
      )
      return
    }

    for runId in runIds {
      try AuditLogGRDB.insertAudit(
        db,
        AuditEvent(
          actor: .owner,
          action: .turnSuperseded,
          argsRedacted: "/new",
          decision: "superseded",
          runId: runId,
          sessionId: sessionId,
          ts: now
        )
      )
    }
  }

  private static func transitionRun(
    _ db: Database,
    runId: Int64,
    event: RunEvent,
    now: Date
  ) throws -> RunState? {
    guard
      let state = try currentRunState(db, runId: runId),
      let nextState = RunFSM.reduce(state: state, on: event)
    else {
      return nil
    }

    try db.execute(
      sql: "UPDATE runs SET state = ?, updated_ts = ? WHERE id = ?",
      arguments: [nextState.rawValue, now, runId]
    )

    return nextState
  }

  private static func currentRunState(_ db: Database, runId: Int64) throws -> RunState? {
    let rawState = try String.fetchOne(
      db,
      sql: "SELECT state FROM runs WHERE id = ?",
      arguments: [runId]
    )

    guard let rawState else {
      return nil
    }

    return RunState(rawValue: rawState)
  }
}
