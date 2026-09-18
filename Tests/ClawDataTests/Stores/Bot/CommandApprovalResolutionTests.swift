import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite
struct CommandApprovalResolutionTests {
  private struct Fixture {
    let queue: DatabaseQueue

    let commands: CommandStoreGRDB
    let approvals: ApprovalStoreGRDB

    let runID: Int64
    let approvalID: Int64
  }

  /// One session, one run parked at AWAITING_APPROVAL through the real reducer, and one PENDING
  /// approval inserted through the store's own seam — the exact shape `/stop`//`new` must resolve.
  private func makeParkedFixture() throws -> Fixture {
    let queue = try TestDatabase.make()
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let claim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateID: 1,
        sessionKey: SessionKey.telegramDM(chatID: 7),
        chatID: 7,
        userID: 7,
        text: "write the plan",
        isEdited: false,
        ts: Date()
      )
    )
    let sessionID = try #require(claim.sessionID)
    let runID = try #require(claim.runID)
    let runs = RunStoreGRDB(writer: queue)
    _ = try #require(try runs.pickUp(runID: runID, now: Date()))

    let now = Date()
    let approvalID = try queue.write { db -> Int64 in
      _ = try RunStoreGRDB.transitionRun(
        db,
        runID: runID,
        event: .suspendForApproval,
        now: now,
        terminal: nil
      )
      let canonicalArgs = #"{"path":"/w/plan.md"}"#
      return try ApprovalStoreGRDB.insertApproval(
        db,
        NewApproval(
          runID: runID,
          sessionID: sessionID,
          tool: "file_write",
          canonicalArgsJSON: canonicalArgs,
          canonicalTarget: "/w/plan.md",
          argsHash: ApprovalArgsHash.sha256Hex(canonicalArgs),
          policyVersion: "pv16",
          ownerUserID: 7,
          nonce: "nonce-a",
          observationMessageID: 1,
          toolCallID: "c1",
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
      runID: runID,
      approvalID: approvalID
    )
  }

  private func audits(_ queue: DatabaseQueue) throws -> [(action: String, decision: String)] {
    try queue.read { db in
      try Row.fetchAll(db, sql: "SELECT action, decision FROM audit_events ORDER BY id").map {
        (row) in
        (action: row["action"], decision: row["decision"])
      }
    }
  }

  @Test
  func stopResolvesTheParkedApprovalToRejectedCancelled() throws {
    // given
    let env = try makeParkedFixture()

    // when
    let result = try env.commands.applyStop(
      updateID: 2,
      sessionKey: SessionKey.telegramDM(chatID: 7),
      now: Date()
    )

    // then — the suspended run is CANCELLED and its approval is REJECTED (decision cancelled),
    // reported for the coordinator signal — no second PENDING row, no orphan (§6.4)
    #expect(result.cancelledRunIDs == [env.runID])
    #expect(result.resolvedApprovalIDs == [env.approvalID])
    #expect(try env.approvals.approval(id: env.approvalID)?.state == .rejected)
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

  @Test
  func newResolvesTheParkedApprovalToRejectedSuperseded() throws {
    // given
    let env = try makeParkedFixture()

    // when
    let result = try env.commands.applyNew(
      updateID: 2,
      sessionKey: SessionKey.telegramDM(chatID: 7),
      now: Date()
    )

    // then
    #expect(result.supersededRunIDs == [env.runID])
    #expect(result.resolvedApprovalIDs == [env.approvalID])
    #expect(try env.approvals.approval(id: env.approvalID)?.state == .rejected)
    #expect(
      try audits(env.queue).contains { row in
        row.action == AuditAction.approvalDenied.rawValue
          && row.decision == ApprovalDecision.superseded.rawValue
      }
    )
  }

  @Test
  func stopWithNoParkedApprovalResolvesNothing() throws {
    // given — a session with no runs at all
    let queue = try TestDatabase.make()
    let commands = CommandStoreGRDB(writer: queue)

    // when
    let result = try commands.applyStop(
      updateID: 1,
      sessionKey: SessionKey.telegramDM(chatID: 7),
      now: Date()
    )

    // then — nothing to resolve; the field is present and empty
    #expect(result.cancelledRunIDs.isEmpty)
    #expect(result.resolvedApprovalIDs.isEmpty)
  }
}
