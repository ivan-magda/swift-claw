import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct V13MigrationTests {
  @Test func upgradePreservesCrashWindowsAndSettledLegacyObservations() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrator.migrate(queue, upTo: "v12")
    let expectedUnresolved = try queue.write { db in
      try db.execute(
        sql: "INSERT INTO sessions(session_key, created_ts, updated_ts) VALUES (?, ?, ?)",
        arguments: [SessionKey.telegramDM(chatId: 7), Self.now, Self.now]
      )
      let sessionId = db.lastInsertedRowID
      let awaitingRun = try Self.insertRun(db, sessionId: sessionId, state: .awaitingApproval)
      let unclaimed = try Self.insertApproval(db, runId: awaitingRun, sessionId: sessionId)
      let runningRun = try Self.insertRun(db, sessionId: sessionId, state: .running)
      let claimed = try Self.insertApproval(db, runId: runningRun, sessionId: sessionId)
      let completedRun = try Self.insertRun(db, sessionId: sessionId, state: .done)
      _ = try Self.insertApproval(db, runId: completedRun, sessionId: sessionId)
      let failedRun = try Self.insertRun(db, sessionId: sessionId, state: .failed)
      _ = try Self.insertApproval(
        db,
        runId: failedRun,
        sessionId: sessionId,
        content: "The action completed before a later provider failure."
      )
      let reparkedRun = try Self.insertRun(db, sessionId: sessionId, state: .awaitingApproval)
      _ = try Self.insertApproval(db, runId: reparkedRun, sessionId: sessionId)
      let pending = try Self.insertApproval(
        db,
        runId: reparkedRun,
        sessionId: sessionId,
        state: .pending
      )
      let deniedRun = try Self.insertRun(db, sessionId: sessionId, state: .awaitingApproval)
      let denied = try Self.insertApproval(
        db,
        runId: deniedRun,
        sessionId: sessionId,
        state: .rejected
      )
      return Set([unclaimed, claimed, pending, denied])
    }

    // when
    try ClawDatabase.migrate(queue)
    let unresolved = try ApprovalStoreGRDB(writer: queue).unresolvedAtBoot()

    // then
    #expect(Set(unresolved.map(\.id)) == expectedUnresolved)
  }
}

// MARK: - Legacy Rows

private extension V13MigrationTests {
  static let now = Date(timeIntervalSince1970: 1_700_000_000)

  static func insertRun(_ db: Database, sessionId: Int64, state: RunState) throws -> Int64 {
    try db.execute(
      sql: "INSERT INTO runs(session_id, state, created_ts, updated_ts) VALUES (?, ?, ?, ?)",
      arguments: [sessionId, state.rawValue, now, now]
    )
    return db.lastInsertedRowID
  }

  static func insertApproval(
    _ db: Database,
    runId: Int64,
    sessionId: Int64,
    state: ApprovalState = .approved,
    content: String = RunStoreGRDB.placeholderObservationContent
  ) throws -> Int64 {
    let toolCallId = "call-\(runId)-\(state.rawValue)"
    try db.execute(
      sql: """
        INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_call_id)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        sessionId, runId, MessageRole.tool.rawValue, content, Provenance.untrusted.rawValue,
        now, toolCallId,
      ]
    )
    let observationId = db.lastInsertedRowID
    try db.execute(
      sql: """
        INSERT INTO approvals(run_id, session_id, state, tool, canonical_args, canonical_target,
          args_hash, policy_version, owner_user_id, nonce, observation_message_id, tool_call_id,
          reason, created_ts, expires_ts)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        runId, sessionId, state.rawValue, "remote_write", "{}", "remote-target",
        ApprovalArgsHash.sha256Hex("{}"), "policy", 7, toolCallId, observationId, toolCallId,
        ApprovalReason.askTier.rawValue, 1_700_000_000, 1_700_003_600,
      ]
    )
    return db.lastInsertedRowID
  }
}
