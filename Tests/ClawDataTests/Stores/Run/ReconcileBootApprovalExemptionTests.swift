import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct ReconcileBootApprovalExemptionTests {
  @Test func reconcileFailsRunningOrphansButLeavesSuspendedRunsParked() throws {
    // given — a crashed RUNNING run and a suspended AWAITING_APPROVAL run in the reopened DB
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO sessions(session_key, created_ts, updated_ts, tainted)
          VALUES ('tg:dm:7', ?, ?, 0)
          """,
        arguments: [Date(), Date()]
      )
      try db.execute(
        sql: "INSERT INTO runs(session_id, state, created_ts, updated_ts) VALUES (1, ?, ?, ?)",
        arguments: [RunState.running.rawValue, Date(), Date()]
      )
      try db.execute(
        sql: "INSERT INTO runs(session_id, state, created_ts, updated_ts) VALUES (1, ?, ?, ?)",
        arguments: [RunState.awaitingApproval.rawValue, Date(), Date()]
      )
    }
    let runs = RunStoreGRDB(writer: queue)

    // when
    _ = try runs.reconcileRunsAtBoot(
      now: Date(),
      degradationText: "unfinished",
      heartbeatNoticeChatId: nil
    )

    // then — the RUNNING orphan is failed; the suspended run is DELIBERATELY exempt (§7), left for
    // the approval boot reconciliation to re-park
    let states = try queue.read { db in
      try Row.fetchAll(db, sql: "SELECT state FROM runs ORDER BY id").map { row in
        row["state"] as String
      }
    }
    #expect(states == [RunState.failed.rawValue, RunState.awaitingApproval.rawValue])
  }

  private func makeRunningOrphan(
    _ queue: DatabaseQueue,
    sentRowIsApprovalPrompt: Bool
  ) throws -> Int64 {
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO sessions(session_key, created_ts, updated_ts, tainted)
          VALUES ('tg:dm:7', ?, ?, 0)
          """,
        arguments: [Date(), Date()]
      )
      try db.execute(
        sql: "INSERT INTO runs(session_id, state, created_ts, updated_ts) VALUES (1, ?, ?, ?)",
        arguments: [RunState.running.rawValue, Date(), Date()]
      )
      let runId = db.lastInsertedRowID

      var approvalId: Int64?
      if sentRowIsApprovalPrompt {
        try db.execute(
          sql: """
            INSERT INTO messages(session_id, run_id, role, content, provenance, ts, tool_call_id)
            VALUES (1, ?, 'tool', 'filled result', 'untrusted', ?, 'c1')
            """,
          arguments: [runId, Date()]
        )
        let argsJSON = #"{"path":"/w/plan.md"}"#
        approvalId = try ApprovalStoreGRDB.insertApproval(
          db,
          NewApproval(
            runId: runId,
            sessionId: 1,
            tool: "file_write",
            canonicalArgsJSON: argsJSON,
            canonicalTarget: "/w/plan.md",
            argsHash: ApprovalArgsHash.sha256Hex(argsJSON),
            policyVersion: "pv",
            ownerUserId: 7,
            nonce: "n-orphan",
            observationMessageId: db.lastInsertedRowID,
            toolCallId: "c1",
            reason: .askTier,
            createdTs: Date(),
            expiresTs: Date().addingTimeInterval(3600)
          )
        )
      }
      try db.execute(
        sql: """
          INSERT INTO outbound_deliveries(run_id, step_index, chat_id, dedup_key, payload,
            payload_hash, approval_id, status, created_ts)
          VALUES (?, 0, 7, ?, 'sent earlier', 'h', ?, 'SENT', ?)
          """,
        arguments: [runId, "\(runId):0", approvalId, Date()]
      )
      return runId
    }
  }

  @Test func reconcileNotifiesARunningOrphanWhoseOnlyDeliveryWasItsApprovalPrompt() throws {
    // given — the recorded-but-continuation-lost window: the approval prompt was delivered (its
    // keyboard chunk is the newest SENT row), the owner approved, the action ran and recorded,
    // and the daemon died during the continuation — the run is a RUNNING orphan at boot
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let runId = try makeRunningOrphan(queue, sentRowIsApprovalPrompt: true)
    let runs = RunStoreGRDB(writer: queue)

    // when
    let replies = try runs.reconcileRunsAtBoot(
      now: Date(),
      degradationText: "unfinished",
      heartbeatNoticeChatId: nil
    )

    // then — a delivered PROMPT is not a delivered reply: the owner has heard nothing since
    // approving, so the F22 degradation notice must still fire
    #expect(replies.map(\.runId) == [runId])
    #expect(replies.map(\.chatId) == [7])
  }

  @Test func reconcileStaysSilentWhenTheOwnerAlreadySawAReply() throws {
    // given — a RUNNING orphan whose newest SENT row is a genuine reply chunk (no approval link)
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    _ = try makeRunningOrphan(queue, sentRowIsApprovalPrompt: false)
    let runs = RunStoreGRDB(writer: queue)

    // when
    let replies = try runs.reconcileRunsAtBoot(
      now: Date(),
      degradationText: "unfinished",
      heartbeatNoticeChatId: nil
    )

    // then — the owner already received output for this run; no double notice
    #expect(replies.isEmpty)
  }
}
