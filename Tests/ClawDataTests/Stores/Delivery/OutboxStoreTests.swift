import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct OutboxStoreTests {
  private struct Fixture {
    let outbox: OutboxStoreGRDB
    let runs: RunStoreGRDB
    let approvals: ApprovalStoreGRDB
    let writer: DatabaseQueue
    let sessionId: Int64
    let runId: Int64
  }

  private func fixture() throws -> Fixture {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let claim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateId: 1,
        sessionKey: SessionKey.telegramDM(chatId: 42),
        chatId: 42,
        userId: 42,
        text: "seed",
        isEdited: false,
        ts: Date()
      )
    )
    let sessionId = try #require(claim.sessionId)
    let runId = try #require(claim.runId)
    return Fixture(
      outbox: OutboxStoreGRDB(writer: queue),
      runs: RunStoreGRDB(writer: queue),
      approvals: ApprovalStoreGRDB(writer: queue),
      writer: queue,
      sessionId: sessionId,
      runId: runId
    )
  }

  private func sampleApproval(runId: Int64, sessionId: Int64) -> NewApproval {
    NewApproval(
      runId: runId,
      sessionId: sessionId,
      tool: "file_write",
      canonicalArgsJSON: "{\"path\":\"notes.md\"}",
      canonicalTarget: "/workspace/notes.md",
      argsHash: "deadbeef",
      policyVersion: "0123456789abcdef",
      ownerUserId: 42,
      nonce: ApprovalNonce.generate(),
      observationMessageId: 1,
      toolCallId: "call-1",
      reason: .askTier,
      createdTs: Date(),
      expiresTs: Date().addingTimeInterval(3600)
    )
  }

  @Test func claimIsIdempotentOnTheDeterministicKey() throws {
    // given
    let env = try fixture()

    // when — the same run_id:step_index claimed twice
    let first = try env.outbox.claimOutbound(
      runId: env.runId,
      stepIndex: 0,
      chatId: 42,
      payload: "p",
      payloadHash: "h"
    )
    let second = try env.outbox.claimOutbound(
      runId: env.runId,
      stepIndex: 0,
      chatId: 42,
      payload: "p",
      payloadHash: "h"
    )

    // then — INSERT OR IGNORE dedups; one PENDING row
    #expect(first)
    #expect(second == false)
    #expect(try env.outbox.pendingOutbound().count == 1)
  }

  @Test func markSentRemovesRowFromPending() throws {
    // given
    let env = try fixture()
    let claimed = try env.outbox.claimOutbound(
      runId: env.runId,
      stepIndex: 0,
      chatId: 42,
      payload: "p",
      payloadHash: "h"
    )
    #expect(claimed)

    // when
    try env.outbox.markSent(
      runId: env.runId,
      stepIndex: 0,
      telegramMessageId: 555,
      now: Date()
    )

    // then
    #expect(try env.outbox.pendingOutbound().isEmpty)
  }

  @Test func activeClaimOnlyInsertsForRunningRun() throws {
    // given
    let env = try fixture()

    // when / then
    #expect(
      try env.outbox.claimOutboundIfRunActive(
        runId: env.runId,
        stepIndex: 0,
        chatId: 42,
        payload: "pending",
        payloadHash: "p"
      ) == false
    )
    _ = try #require(try env.runs.pickUp(runId: env.runId, now: Date()))
    #expect(
      try env.outbox.claimOutboundIfRunActive(
        runId: env.runId,
        stepIndex: 0,
        chatId: 42,
        payload: "running",
        payloadHash: "r"
      )
    )
    _ = try env.runs.cancelActiveRun(
      sessionId: env.sessionId,
      reason: .cancelled,
      now: Date()
    )
    #expect(
      try env.outbox.claimOutboundIfRunActive(
        runId: env.runId,
        stepIndex: 1,
        chatId: 42,
        payload: "cancelled",
        payloadHash: "c"
      ) == false
    )
  }

  @Test func pendingOutboundCarriesApprovalIdAndReplyMarkup() throws {
    // given — an approvals row and a PENDING delivery linked to it, carrying an inline keyboard
    let env = try fixture()
    let approvalId = try env.writer.write { db in
      try ApprovalStoreGRDB.insertApproval(
        db,
        sampleApproval(runId: env.runId, sessionId: env.sessionId)
      )
    }
    let markup = "{\"inline_keyboard\":[[{\"text\":\"Approve\",\"callback_data\":\"apr:x:y\"}]]}"

    // when
    _ = try env.outbox.claimOutbound(
      runId: env.runId,
      stepIndex: 0,
      chatId: 42,
      payload: "prompt",
      payloadHash: "h",
      approvalId: approvalId,
      replyMarkup: markup
    )
    let rows = try env.outbox.pendingOutbound()

    // then — both new fields round-trip through the SELECT
    let row = try #require(rows.first)
    #expect(row.approvalId == approvalId)
    #expect(row.replyMarkup == markup)
  }

  @Test func markSentLinksPromptMessageIdForApprovalBearingRow() throws {
    // given — an approvals row (prompt_message_id NULL) and its delivery row
    let env = try fixture()
    let approvalId = try env.writer.write { db in
      try ApprovalStoreGRDB.insertApproval(
        db,
        sampleApproval(runId: env.runId, sessionId: env.sessionId)
      )
    }
    _ = try env.outbox.claimOutbound(
      runId: env.runId,
      stepIndex: 0,
      chatId: 42,
      payload: "prompt",
      payloadHash: "h",
      approvalId: approvalId,
      replyMarkup: "{\"inline_keyboard\":[]}"
    )

    // when — the dispatcher records the delivered Telegram message id
    try env.outbox.markSent(runId: env.runId, stepIndex: 0, telegramMessageId: 999, now: Date())

    // then — the linked approval got prompt_message_id in the same transaction
    let approval = try #require(try env.approvals.approval(id: approvalId))
    #expect(approval.promptMessageId == 999)
  }

  @Test func markSentLeavesUnlinkedApprovalsUntouched() throws {
    // given — an approvals row NOT referenced by any delivery, and a plain (approval_id NULL) row
    let env = try fixture()
    let approvalId = try env.writer.write { db in
      try ApprovalStoreGRDB.insertApproval(
        db,
        sampleApproval(runId: env.runId, sessionId: env.sessionId)
      )
    }
    _ = try env.outbox.claimOutbound(
      runId: env.runId,
      stepIndex: 0,
      chatId: 42,
      payload: "plain",
      payloadHash: "h"
    )
    // the plain row carries nil approval_id/reply_markup — assert BEFORE markSent flips it to SENT
    // (a SENT row drops out of pendingOutbound, so this read must precede the mark).
    let plainRow = try #require(try env.outbox.pendingOutbound().first { $0.approvalId == nil })
    #expect(plainRow.replyMarkup == nil)

    // when — marking the plain row sent must not touch any approval
    try env.outbox.markSent(runId: env.runId, stepIndex: 0, telegramMessageId: 111, now: Date())

    // then — the unrelated approval keeps its NULL prompt_message_id
    let approval = try #require(try env.approvals.approval(id: approvalId))
    #expect(approval.promptMessageId == nil)
  }
}
