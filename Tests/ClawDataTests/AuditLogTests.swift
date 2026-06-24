import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct AuditLogTests {
  private func freshLog() throws -> (AuditLogGRDB, DatabaseQueue) {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    return (AuditLogGRDB(writer: queue), queue)
  }

  @Test func appendPersistsEveryColumnInOrder() throws {
    // given
    let (log, queue) = try freshLog()
    let when = Date(timeIntervalSince1970: 1_700_000_000)
    let event = AuditEvent(
      actor: .owner,
      action: .toolCall,
      tool: "web.fetch",
      argsRedacted: "{\"url\":\"<redacted>\"}",
      resultSize: 4096,
      decision: "allow",
      runId: 7,
      sessionId: 3,
      ts: when
    )

    // when
    try log.appendAudit(event)

    // then
    let row = try #require(
      try queue.read { db in
        try Row.fetchOne(
          db,
          sql: """
            SELECT ts, actor, action, tool, args_redacted, result_size, decision, run_id, session_id
            FROM audit_events
            """
        )
      }
    )
    let ts: Date = try #require(row["ts"])
    let actor: String = try #require(row["actor"])
    let action: String = try #require(row["action"])
    let tool: String? = row["tool"]
    let argsRedacted: String = try #require(row["args_redacted"])
    let resultSize: Int = try #require(row["result_size"])
    let decision: String = try #require(row["decision"])
    let runId: Int64? = row["run_id"]
    let sessionId: Int64? = row["session_id"]
    #expect(ts == when)
    #expect(actor == "owner")
    #expect(action == "tool_call")
    #expect(tool == "web.fetch")
    #expect(argsRedacted == "{\"url\":\"<redacted>\"}")
    #expect(resultSize == 4096)
    #expect(decision == "allow")
    #expect(runId == 7)
    #expect(sessionId == 3)
  }

  @Test func appendStoresNullForOmittedToolRunAndSession() throws {
    // given
    let (log, queue) = try freshLog()
    let event = AuditEvent(
      actor: .owner,
      action: .messageIn,
      ts: Date(timeIntervalSince1970: 1_700_000_000)
    )

    // when
    try log.appendAudit(event)

    // then
    let row = try #require(
      try queue.read { db in
        try Row.fetchOne(db, sql: "SELECT tool, run_id, session_id FROM audit_events")
      }
    )
    let tool: String? = row["tool"]
    let runId: Int64? = row["run_id"]
    let sessionId: Int64? = row["session_id"]
    #expect(tool == nil)
    #expect(runId == nil)
    #expect(sessionId == nil)
  }
}
