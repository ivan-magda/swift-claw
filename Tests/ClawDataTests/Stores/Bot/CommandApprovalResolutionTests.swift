import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct CommandApprovalResolutionTests {
  private struct Fixture {
    let queue: DatabaseQueue
    let commands: CommandStoreGRDB
    let approvals: ApprovalStoreGRDB
    let sessionId: Int64
    let runId: Int64
    let approvalId: Int64
  }

  /// One session, one run parked at AWAITING_APPROVAL through the real reducer, and one PENDING
  /// approval inserted through the store's own seam — the exact shape `/stop`//`new` must resolve.
  private func makeParkedFixture() throws -> Fixture {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let claim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateId: 1,
        sessionKey: SessionKey.telegramDM(chatId: 7),
        chatId: 7,
        userId: 7,
        text: "write the plan",
        isEdited: false,
        ts: Date()
      )
    )
    let sessionId = try #require(claim.sessionId)
    let runId = try #require(claim.runId)
    let runs = RunStoreGRDB(writer: queue)
    _ = try #require(try runs.pickUp(runId: runId, now: Date()))

    let now = Date()
    let approvalId = try queue.write { db -> Int64 in
      _ = try RunStoreGRDB.transitionRun(db, runId: runId, event: .suspendForApproval, now: now)
      let canonicalArgs = #"{"path":"/w/plan.md"}"#
      return try ApprovalStoreGRDB.insertApproval(
        db,
        NewApproval(
          runId: runId,
          sessionId: sessionId,
          tool: "file_write",
          canonicalArgsJSON: canonicalArgs,
          canonicalTarget: "/w/plan.md",
          argsHash: ApprovalArgsHash.sha256Hex(canonicalArgs),
          policyVersion: "pv16",
          ownerUserId: 7,
          nonce: "nonce-a",
          observationMessageId: 1,
          toolCallId: "c1",
          reason: .askTier,
          createdTs: now,
          expiresTs: now.addingTimeInterval(3600)
        )
      )
    }

    return Fixture(
      queue: queue,
      commands: CommandStoreGRDB(writer: queue),
      approvals: ApprovalStoreGRDB(writer: queue),
      sessionId: sessionId,
      runId: runId,
      approvalId: approvalId
    )
  }

  private func audits(_ queue: DatabaseQueue) throws -> [(action: String, decision: String)] {
    try queue.read { db in
      try Row.fetchAll(db, sql: "SELECT action, decision FROM audit_events ORDER BY id")
        .map { row in (action: row["action"], decision: row["decision"]) }
    }
  }

  @Test func stopResolvesTheParkedApprovalToRejectedCancelled() throws {
    // given
    let env = try makeParkedFixture()

    // when
    let result = try env.commands.applyStop(
      updateId: 2,
      sessionKey: SessionKey.telegramDM(chatId: 7),
      now: Date()
    )

    // then — the suspended run is CANCELLED and its approval is REJECTED (decision cancelled),
    // reported for the coordinator signal — no second PENDING row, no orphan (§6.4)
    #expect(result.cancelledRunIds == [env.runId])
    #expect(result.resolvedApprovalIds == [env.approvalId])
    #expect(try env.approvals.approval(id: env.approvalId)?.state == .rejected)
    let pending = try env.queue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM approvals WHERE state = 'PENDING'")
    }
    #expect(pending == 0)
    #expect(
      try audits(env.queue).contains { row in
        row.action == AuditAction.approvalDenied.rawValue
          && row.decision == ApprovalDecision.cancelled.rawValue
      }
    )
  }

  @Test func newResolvesTheParkedApprovalToRejectedSuperseded() throws {
    // given
    let env = try makeParkedFixture()

    // when
    let result = try env.commands.applyNew(
      updateId: 2,
      sessionKey: SessionKey.telegramDM(chatId: 7),
      now: Date()
    )

    // then
    #expect(result.supersededRunIds == [env.runId])
    #expect(result.resolvedApprovalIds == [env.approvalId])
    #expect(try env.approvals.approval(id: env.approvalId)?.state == .rejected)
    #expect(
      try audits(env.queue).contains { row in
        row.action == AuditAction.approvalDenied.rawValue
          && row.decision == ApprovalDecision.superseded.rawValue
      }
    )
  }

  @Test func stopWithNoParkedApprovalResolvesNothing() throws {
    // given — a session with no runs at all
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let commands = CommandStoreGRDB(writer: queue)

    // when
    let result = try commands.applyStop(
      updateId: 1,
      sessionKey: SessionKey.telegramDM(chatId: 7),
      now: Date()
    )

    // then — nothing to resolve; the field is present and empty
    #expect(result.cancelledRunIds.isEmpty)
    #expect(result.resolvedApprovalIds.isEmpty)
  }
}
