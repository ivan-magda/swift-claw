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
}
