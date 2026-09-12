import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct OutboxStoreTests {
  @Test func markSentRemovesRowFromPending() throws {
    // given
    let env = try fixture()
    try OutboxFixture.commitReply(
      in: env.writer,
      runId: env.runId,
      chunks: [OutboxChunk(stepIndex: 0, chatId: 42, payload: "p", payloadHash: "h")]
    )

    // when
    try env.outbox.markSent(
      deliveryKey: OutboxDedupKey.make(runId: env.runId, stepIndex: 0),
      telegramMessageId: 555,
      now: Date()
    )

    // then
    #expect(try env.outbox.pendingOutbound().isEmpty)
  }

  @Test func pendingRepliesPrecedeRunlessNoticesInRunOrder() throws {
    // given — a notice followed by concurrent chats completing in reverse run order
    let env = try fixture()
    let secondClaim = try SessionMessageStoreGRDB(writer: env.writer).claimAndPersistInbound(
      inbound(updateId: 2, chatId: 43)
    )
    let secondRunId = try #require(secondClaim.runId)
    _ = try #require(try RunStoreGRDB(writer: env.writer).pickUp(runId: secondRunId, now: Date()))
    let notice = LearningNoticeChunk(
      subjectDigest: "candidate",
      ordinal: 0,
      chatId: 42,
      payload: "candidate ready",
      payloadHash: "hash"
    )
    let noticeKey = "fixture-learning-notice"
    try OutboxFixture.seedNotice(in: env.writer, chunk: notice, deliveryKey: noticeKey)
    try OutboxFixture.commitReply(
      in: env.writer,
      runId: secondRunId,
      chunks: [OutboxChunk(stepIndex: 0, chatId: 43, payload: "newer", payloadHash: "h")]
    )
    try OutboxFixture.commitReply(
      in: env.writer,
      runId: env.runId,
      chunks: [
        OutboxChunk(stepIndex: 0, chatId: 42, payload: "first", payloadHash: "h"),
        OutboxChunk(stepIndex: 1, chatId: 42, payload: "second", payloadHash: "h"),
      ]
    )

    // when
    let pending = try env.outbox.pendingOutbound()

    // then
    #expect(
      pending.map(\.deliveryKey) == [
        OutboxDedupKey.make(runId: env.runId, stepIndex: 0),
        OutboxDedupKey.make(runId: env.runId, stepIndex: 1),
        OutboxDedupKey.make(runId: secondRunId, stepIndex: 0),
        noticeKey,
      ]
    )
  }

  @Test func pendingOutboundCarriesApprovalIdAndReplyMarkup() throws {
    // given
    let env = try fixture()
    let markup = "{\"inline_keyboard\":[[{\"text\":\"Approve\",\"callback_data\":\"apr:x:y\"}]]}"
    let approvalId = try suspend(env, markup: markup)

    // when
    let rows = try env.outbox.pendingOutbound()

    // then
    let row = try #require(rows.first)
    #expect(row.approvalId == approvalId)
    #expect(row.replyMarkup == markup)
  }

  @Test func markSentLinksPromptMessageIdForApprovalBearingRow() throws {
    // given
    let env = try fixture()
    let approvalId = try suspend(env)

    // when
    try env.outbox.markSent(
      deliveryKey: OutboxDedupKey.make(runId: env.runId, stepIndex: 0),
      telegramMessageId: 999,
      now: Date()
    )

    // then
    let approval = try #require(try env.approvals.approval(id: approvalId))
    #expect(approval.promptMessageId == 999)
  }

  @Test func markSentLeavesUnlinkedApprovalsUntouched() throws {
    // given — a suspended approval and a separate completed reply with no approval link
    let env = try fixture()
    let approvalId = try suspend(env)
    let secondClaim = try SessionMessageStoreGRDB(writer: env.writer).claimAndPersistInbound(
      inbound(updateId: 2, chatId: 43)
    )
    let replyRunId = try #require(secondClaim.runId)
    _ = try #require(try RunStoreGRDB(writer: env.writer).pickUp(runId: replyRunId, now: Date()))
    try OutboxFixture.commitReply(
      in: env.writer,
      runId: replyRunId,
      chunks: [OutboxChunk(stepIndex: 0, chatId: 43, payload: "plain", payloadHash: "h")]
    )

    // when
    try env.outbox.markSent(
      deliveryKey: OutboxDedupKey.make(runId: replyRunId, stepIndex: 0),
      telegramMessageId: 111,
      now: Date()
    )

    // then
    let approval = try #require(try env.approvals.approval(id: approvalId))
    #expect(approval.promptMessageId == nil)
  }
}

// MARK: - Fixtures

private extension OutboxStoreTests {
  struct Fixture {
    let outbox: OutboxStoreGRDB
    let approvals: ApprovalStoreGRDB
    let writer: DatabaseQueue
    let sessionId: Int64
    let runId: Int64
  }

  func fixture() throws -> Fixture {
    let queue = try TestDatabase.make()
    let claim = try SessionMessageStoreGRDB(writer: queue).claimAndPersistInbound(
      inbound(updateId: 1)
    )
    let sessionId = try #require(claim.sessionId)
    let runId = try #require(claim.runId)
    _ = try #require(try RunStoreGRDB(writer: queue).pickUp(runId: runId, now: Date()))
    return Fixture(
      outbox: OutboxStoreGRDB(writer: queue),
      approvals: ApprovalStoreGRDB(writer: queue),
      writer: queue,
      sessionId: sessionId,
      runId: runId
    )
  }

  func inbound(updateId: Int64, chatId: Int64 = 42) -> InboundMessage {
    InboundMessage(
      updateId: updateId,
      sessionKey: SessionKey.telegramDM(chatId: chatId),
      chatId: chatId,
      userId: chatId,
      text: "seed",
      isEdited: false,
      ts: Date()
    )
  }

  func suspend(_ env: Fixture, markup: String = "{\"inline_keyboard\":[]}") throws -> Int64 {
    let now = Date()
    let recorded = RecordedToolAction(
      tool: "file_write",
      canonicalArgsJSON: #"{"path":"notes.md"}"#,
      argsHash: "deadbeef",
      canonicalTarget: "/workspace/notes.md",
      reason: .askTier,
      presentation: ToolApprovalPresentation(
        blastRadius: "create",
        contentPreview: "",
        warnings: []
      )
    )
    let receipt = try RunStoreGRDB(writer: env.writer).commitSuspendedTurn(
      runId: env.runId,
      sessionId: env.sessionId,
      commit: SuspendedTurnCommit(
        assistantContent: "Let me save that.",
        toolCallsJSON: #"[{"id":"call-1","name":"file_write","arguments":"{}"}]"#,
        completedObservations: [],
        pending: PendingToolAction(toolCallId: "call-1", recorded: recorded),
        ownerUserId: 42,
        nonce: ApprovalNonce.generate(),
        promptChunks: [
          OutboxChunk(
            stepIndex: 0,
            chatId: 42,
            payload: "prompt",
            payloadHash: "h",
            replyMarkup: markup
          )
        ],
        setTainted: false,
        setPrivateData: false,
        expiresTs: now.addingTimeInterval(3600)
      ),
      now: now
    )
    return receipt.approvalId
  }
}
