import ClawCore
import Crypto
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct ApprovedMemoryWriteExactlyOnceTests {
  private func sha256Hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { byte in String(format: "%02x", byte) }.joined()
  }

  @Test func rerunningTheFusedWriteIsANoOpOnceTheObservationIsFilled() throws {
    // given — a real suspended run holding a memory_write approval
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let sessionMessages = SessionMessageStoreGRDB(writer: queue)
    let runs = RunStoreGRDB(writer: queue)
    let now = Date(timeIntervalSince1970: 1_750_000_000)

    let claim = try sessionMessages.claimAndPersistInbound(
      InboundMessage(
        updateId: 1,
        sessionKey: SessionKey.telegramDM(chatId: 7),
        chatId: 7,
        userId: 7,
        text: "remember this",
        isEdited: false,
        ts: now
      )
    )
    let runId = try #require(claim.runId)
    let sessionId = try #require(claim.sessionId)
    _ = try runs.pickUp(runId: runId, policyVersion: "0123456789abcdef", now: now)

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
      runId: runId,
      sessionId: sessionId,
      commit: SuspendedTurnCommit(
        assistantContent: "",
        toolCallsJSON: #"[{"id":"m1","name":"memory_write","arguments":{}}]"#,
        completedObservations: [],
        pending: PendingToolAction(toolCallId: "m1", recorded: recorded),
        ownerUserId: 7,
        nonce: ApprovalNonce.generate(),
        promptChunks: [
          OutboxChunk(stepIndex: 0, chatId: 7, payload: "approve?", payloadHash: "h")
        ],
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
      sessionId: sessionId
    )

    // when — the fused write runs twice (the §6.3 crash-window re-run shape)
    let first = try runs.applyApprovedMemoryWrite(
      runId: runId,
      observationMessageId: receipt.observationMessageId,
      item: item,
      observationContent: "Saved memory item.",
      notResumableObservationContent: "stopped",
      now: now
    )
    let second = try runs.applyApprovedMemoryWrite(
      runId: runId,
      observationMessageId: receipt.observationMessageId,
      item: item,
      observationContent: "Saved memory item.",
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
        arguments: [receipt.observationMessageId]
      ) ?? 0
    }
    #expect(observationCount == 1)
  }
}
