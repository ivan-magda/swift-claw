import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawGateway

/// §5.1/§8.3: the lethal-trifecta gate for `web_fetch` rides the DURABLE fabric. A tainted session
/// holding private data suspends the fetch to a persisted approval (reason exfilTrifecta) — a plain
/// "yes" no longer grants it; only the owner's button callback executes the recorded args.
@Suite(.serialized) struct TrifectaApprovalFlowTests {
  private func firstSessionId(databasePath: String) throws -> Int64 {
    let pool = try ClawDatabase.makePool(path: databasePath)
    return try pool.read { db in
      try Int64.fetchOne(db, sql: "SELECT id FROM sessions ORDER BY id LIMIT 1")
    } ?? 0
  }

  private func armPersistedTrifecta(databasePath: String, sessionId: Int64) throws {
    let pool = try ClawDatabase.makePool(path: databasePath)
    try pool.write { db in
      try db.execute(
        sql: "UPDATE sessions SET tainted = 1, has_private_data = 1 WHERE id = ?",
        arguments: [sessionId]
      )
    }
  }

  @Test func taintedFetchWithPrivateDataSuspendsToADurableApproval() async throws {
    // given — turn 1 creates the session with a plain reply; turn 2 proposes the fetch
    let harness = try makeSC3Harness(
      scripts: [
        [okResponse(content: "hello")],
        [
          toolCallResponse([
            ToolCall(
              id: "f1",
              name: "web_fetch",
              argumentsJSON: #"{"url":"https://news.example/article"}"#
            )
          ]),
          okResponse(content: "Here is what I found."),
        ],
      ],
      httpResponses: [:]
    )

    // when — establish the session, then arm the persisted trifecta legs
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 1, from: 7, text: "hi"))
    _ = try await harness.waitForOutbox(atLeast: 1)
    let sessionId = try firstSessionId(databasePath: harness.databasePath)
    try armPersistedTrifecta(databasePath: harness.databasePath, sessionId: sessionId)

    // then — the fetch proposal SUSPENDS to a durable approval, no ephemeral grant
    _ = await harness.router.handle(rawUpdate: textUpdate(id: 2, from: 7, text: "fetch it"))
    let approval = try #require(
      await pollUntil {
        try fetchApprovals(databasePath: harness.databasePath).first
      }
    )
    #expect(approval.state == ApprovalState.pending.rawValue)
    #expect(approval.tool == "web_fetch")
    #expect(approval.reason == ApprovalReason.exfilTrifecta.rawValue)
    #expect(approval.canonicalTarget == "https://news.example/article")
    #expect(
      try runState(databasePath: harness.databasePath, runId: approval.runId)
        == RunState.awaitingApproval.rawValue
    )

    // when — the owner approves via the button
    _ = await harness.router.handle(
      rawUpdate: callbackUpdate(
        id: 3,
        from: 7,
        data: ApprovalKeyboard.callbackData(
          nonce: approval.nonce,
          verdict: ApprovalKeyboard.approveVerdict
        )
      )
    )

    // then — the recorded fetch runs and the run resumes to DONE; audit trail complete
    _ = try await pollUntilTrue {
      try runState(databasePath: harness.databasePath, runId: approval.runId)
        == RunState.done.rawValue
    }
    let resolved = try fetchApprovals(databasePath: harness.databasePath)
    #expect(resolved.map(\.state) == [ApprovalState.approved.rawValue])
    let audits = try harness.auditRows()
    #expect(audits.contains { row in row.action == AuditAction.approvalRequested.rawValue })
    #expect(audits.contains { row in row.action == AuditAction.approvalGranted.rawValue })
  }
}
