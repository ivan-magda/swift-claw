import ClawCore
import ClawTestSupport
import Crypto
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite
struct ApprovedMemoryWriteExactlyOnceTests {
  private func sha256Hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { byte in
      String(format: "%02x", byte)
    }.joined()
  }

  @Test
  func rerunningTheFusedWriteIsANoOpOnceTheObservationIsFilled() throws {
    // given — a real suspended run holding a memory_write approval
    let queue = try TestDatabase.make()
    let sessionMessages = SessionMessageStoreGRDB(writer: queue)
    let runs = RunStoreGRDB(writer: queue)
    let now = Date(timeIntervalSince1970: 1_750_000_000)

    let claim = try sessionMessages.claimAndPersistInbound(
      InboundMessage(
        updateID: 1,
        sessionKey: SessionKey.telegramDM(chatID: 7),
        chatID: 7,
        userID: 7,
        text: "remember this",
        isEdited: false,
        ts: now
      )
    )
    let runID = try #require(claim.runID)
    let sessionID = try #require(claim.sessionID)
    _ = try runs.pickUp(runID: runID, policyVersion: "0123456789abcdef", now: now)

    let canonicalArgs = #"{"kind":"user","text":"prefers metric units"}"#
    let recorded = RecordedToolAction(
      tool: "memory_write",
      canonicalArgsJSON: canonicalArgs,
      argsHash: sha256Hex(canonicalArgs),
      canonicalTarget: "memory_item:user:0011223344556677",
      reason: .askTier,
      presentation: ToolApprovalPresentation(
        blastRadius: "memory item, kind user",
        contentPreview: "prefers metric units",
        warnings: []
      )
    )
    let receipt = try runs.commitSuspendedTurn(
      runID: runID,
      sessionID: sessionID,
      commit: SuspendedTurnCommit(
        assistantContent: "",
        toolCallsJSON: #"[{"id":"m1","name":"memory_write","arguments":{}}]"#,
        completedObservations: [],
        pending: PendingToolAction(toolCallID: "m1", recorded: recorded),
        ownerUserID: 7,
        nonce: ApprovalNonce.generate(),
        promptChunks: [OutboxChunk(stepIndex: 0, chatID: 7, payload: "approve?", payloadHash: "h")],
        setTainted: false,
        setPrivateData: false,
        expiresTs: now.addingTimeInterval(3600)
      ),
      now: now
    )

    let item = NewMemoryItem(
      text: "prefers metric units",
      kind: .user,
      sensitivity: .normal,
      importance: .normal,
      source: .assistant,
      sessionID: sessionID
    )

    // when — the fused write runs twice (the §6.3 crash-window re-run shape)
    let first = try runs.applyApprovedMemoryWrite(
      runID: runID,
      observationMessageID: receipt.observationMessageID,
      item: item,
      observationContent: "Saved memory item.",
      audit: ApprovedExecutionAudit(tool: "memory_write", argsRedacted: "[REDACTED]"),
      notResumableObservationContent: "stopped",
      now: now
    )
    let second = try runs.applyApprovedMemoryWrite(
      runID: runID,
      observationMessageID: receipt.observationMessageID,
      item: item,
      observationContent: "Saved memory item.",
      audit: ApprovedExecutionAudit(tool: "memory_write", argsRedacted: "[REDACTED]"),
      notResumableObservationContent: "stopped",
      now: now
    )

    // then — exactly one row, source assistant; the second run changed nothing
    #expect(first == .committed)
    #expect(second != .committed)
    let rows = try queue.read { db in
      try Row.fetchAll(db, sql: "SELECT text, source FROM memory_items")
    }
    #expect(rows.count == 1)
    #expect(rows.first?["source"] == "assistant")
    let observationCount = try queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM messages WHERE id = ? AND content = 'Saved memory item.'",
        arguments: [receipt.observationMessageID]
      ) ?? 0
    }
    #expect(observationCount == 1)
    let auditCount = try queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM audit_events WHERE run_id = ? AND action = ?",
        arguments: [runID, AuditAction.toolCall.rawValue]
      ) ?? 0
    }
    #expect(auditCount == 1)
  }
}
