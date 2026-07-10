import ClawCore
import ClawData
import Foundation
import GRDB
import Testing

@testable import ClawGateway

/// Post-retirement contract (spec §8.3): a plain text reply never resolves a tool approval. While a
/// run is parked (AWAITING_APPROVAL, one PENDING `approvals` row), the owner typing "yes" is just an
/// ordinary turn — it queues FIFO behind the parked lane and leaves the approval untouched. Only an
/// authenticated button callback resolves it (proven end-to-end in FileWriteApprovalFlowTests +
/// Task 25's matrix).
@Suite(.serialized) struct PlainReplyDoesNotApproveTests {
  /// Every run row's state, oldest first — the FIFO queue behind the parked lane in durable form.
  private func runStates(databasePath: String) throws -> [String] {
    let pool = try ClawDatabase.makePool(path: databasePath)
    return try pool.read { database in
      try String.fetchAll(database, sql: "SELECT state FROM runs ORDER BY id")
    }
  }

  @Test func plainYesLeavesTheParkedApprovalPending() async throws {
    // given — a file_write proposal suspends the run to a durable checkpoint
    let harness = try makeSC3Harness(
      scripts: [
        [
          toolCallResponse([
            ToolCall(
              id: "w1",
              name: "file_write",
              argumentsJSON: #"{"path":"notes/plan.md","content":"hello","overwrite":false}"#
            )
          ]),
          okResponse(content: "acknowledged the plain message"),
        ]
      ],
      httpResponses: [:]
    )
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "write the plan"))
    let approval = try #require(
      await pollUntil(timeout: .seconds(10)) {
        try fetchApprovals(databasePath: harness.databasePath).first
      }
    )
    #expect(approval.state == ApprovalState.pending.rawValue)

    // when — the owner types a plain "yes" instead of tapping the button
    let yesOutcome = await harness.router.handle(
      rawUpdate: textUpdate(id: 2, from: 7, text: "yes")
    )

    // then — positive proof the "yes" was processed: it persisted as an ordinary SECOND run that
    // queues FIFO behind the held lane (PENDING — the lane task is parked on the approval, so the
    // queued turn never starts)
    #expect(yesOutcome == .processed)
    let states = try #require(
      await pollUntil(timeout: .seconds(10)) {
        let observed = try runStates(databasePath: harness.databasePath)
        return observed.count == 2 ? observed : nil
      }
    )
    #expect(states == [RunState.awaitingApproval.rawValue, RunState.pending.rawValue])

    // and — the approval is UNTOUCHED (a plain reply never approves, §8.3); the run is still
    // parked, the target file was never written, and no approvalGranted audit exists
    #expect(
      try fetchApprovals(databasePath: harness.databasePath).map(\.state)
        == [ApprovalState.pending.rawValue]
    )
    #expect(
      try runState(databasePath: harness.databasePath, runId: approval.runId)
        == RunState.awaitingApproval.rawValue
    )
    #expect(FileManager.default.fileExists(atPath: approval.canonicalTarget) == false)
    let audits = try harness.auditRows()
    #expect(audits.contains { row in row.action == AuditAction.approvalGranted.rawValue } == false)
  }
}
