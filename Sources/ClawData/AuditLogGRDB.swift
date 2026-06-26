import ClawCore
import Foundation
import GRDB

public struct AuditLogGRDB: AuditLog {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  public func appendAudit(_ event: AuditEvent) throws {
    try writer.writeMapping { db in
      try Self.insertAudit(db, event)
    }
  }

  static func insertAudit(_ db: Database, _ event: AuditEvent) throws {
    try db.execute(
      sql: """
        INSERT INTO audit_events(ts, actor, action, tool, args_redacted, result_size, decision, run_id, session_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        event.ts,
        event.actor.rawValue,
        event.action.rawValue,
        event.tool,
        event.argsRedacted,
        event.resultSize,
        event.decision,
        event.runId,
        event.sessionId,
      ]
    )
  }
}
