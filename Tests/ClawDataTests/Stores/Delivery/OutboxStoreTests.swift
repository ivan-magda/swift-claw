import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite
struct OutboxStoreTests {
  @Test
  func markSentRemovesRowFromPending() throws {
    // given
    let env = try fixture()
    try OutboxFixture.commitReply(
      in: env.writer,
      runID: env.runID,
      chunks: [OutboxChunk(stepIndex: 0, chatID: 42, payload: "p", payloadHash: "h")]
    )

    // when
    try env.outbox.markSent(
      deliveryKey: OutboxDedupKey.make(runID: env.runID, stepIndex: 0),
      telegramMessageID: 555,
      now: Date()
    )

    // then
    #expect(try env.outbox.pendingOutbound().isEmpty)
  }

  @Test
  func pendingRepliesPrecedeRunlessNoticesInRunOrder() throws {
    // given — a notice followed by concurrent chats completing in reverse run order
    let env = try fixture()
    let secondClaim = try SessionMessageStoreGRDB(writer: env.writer).claimAndPersistInbound(
      inbound(updateID: 2, chatID: 43)
    )
    let secondRunID = try #require(secondClaim.runID)
    _ = try #require(try RunStoreGRDB(writer: env.writer).pickUp(runID: secondRunID, now: Date()))
    let notice = LearningNoticeChunk(
      subjectDigest: "candidate",
      ordinal: 0,
      chatID: 42,
      payload: "candidate ready",
      payloadHash: "hash"
    )
    let noticeKey = "fixture-learning-notice"
    try OutboxFixture.seedNotice(in: env.writer, chunk: notice, deliveryKey: noticeKey)
    try OutboxFixture.commitReply(
      in: env.writer,
      runID: secondRunID,
      chunks: [OutboxChunk(stepIndex: 0, chatID: 43, payload: "newer", payloadHash: "h")]
    )
    try OutboxFixture.commitReply(
      in: env.writer,
      runID: env.runID,
      chunks: [
        OutboxChunk(stepIndex: 0, chatID: 42, payload: "first", payloadHash: "h"),
        OutboxChunk(stepIndex: 1, chatID: 42, payload: "second", payloadHash: "h"),
      ]
    )

    // when
    let pending = try env.outbox.pendingOutbound()

    // then
    #expect(
      pending.map(\.deliveryKey) == [
        OutboxDedupKey.make(runID: env.runID, stepIndex: 0),
        OutboxDedupKey.make(runID: env.runID, stepIndex: 1),
        OutboxDedupKey.make(runID: secondRunID, stepIndex: 0),
        noticeKey,
      ]
    )
  }

  @Test
  func pendingOutboundCarriesApprovalIDAndReplyMarkup() throws {
    // given
    let env = try fixture()
    let markup = "{\"inline_keyboard\":[[{\"text\":\"Approve\",\"callback_data\":\"apr:x:y\"}]]}"
    let approvalID = try suspend(env, markup: markup)

    // when
    let rows = try env.outbox.pendingOutbound()

    // then
    let row = try #require(rows.first)
    #expect(row.approvalID == approvalID)
    #expect(row.replyMarkup == markup)
  }

  @Test
  func markSentLinksPromptMessageIDForApprovalBearingRow() throws {
    // given
    let env = try fixture()
    let approvalID = try suspend(env)

    // when
    try env.outbox.markSent(
      deliveryKey: OutboxDedupKey.make(runID: env.runID, stepIndex: 0),
      telegramMessageID: 999,
      now: Date()
    )

    // then
    let approval = try #require(try env.approvals.approval(id: approvalID))
    #expect(approval.promptMessageID == 999)
  }

  @Test
  func markSentLeavesUnlinkedApprovalsUntouched() throws {
    // given — a suspended approval and a separate completed reply with no approval link
    let env = try fixture()
    let approvalID = try suspend(env)
    let secondClaim = try SessionMessageStoreGRDB(writer: env.writer).claimAndPersistInbound(
      inbound(updateID: 2, chatID: 43)
    )
    let replyRunID = try #require(secondClaim.runID)
    _ = try #require(try RunStoreGRDB(writer: env.writer).pickUp(runID: replyRunID, now: Date()))
    try OutboxFixture.commitReply(
      in: env.writer,
      runID: replyRunID,
      chunks: [OutboxChunk(stepIndex: 0, chatID: 43, payload: "plain", payloadHash: "h")]
    )

    // when
    try env.outbox.markSent(
      deliveryKey: OutboxDedupKey.make(runID: replyRunID, stepIndex: 0),
      telegramMessageID: 111,
      now: Date()
    )

    // then
    let approval = try #require(try env.approvals.approval(id: approvalID))
    #expect(approval.promptMessageID == nil)
  }
}

// MARK: - Fixtures

private extension OutboxStoreTests {
  struct Fixture {
    let outbox: OutboxStoreGRDB
    let approvals: ApprovalStoreGRDB
    let writer: DatabaseQueue
    let sessionID: Int64
    let runID: Int64
  }

  func fixture() throws -> Fixture {
    let queue = try TestDatabase.make()
    let claim = try SessionMessageStoreGRDB(writer: queue).claimAndPersistInbound(
      inbound(updateID: 1)
    )
    let sessionID = try #require(claim.sessionID)
    let runID = try #require(claim.runID)
    _ = try #require(try RunStoreGRDB(writer: queue).pickUp(runID: runID, now: Date()))
    return Fixture(
      outbox: OutboxStoreGRDB(writer: queue),
      approvals: ApprovalStoreGRDB(writer: queue),
      writer: queue,
      sessionID: sessionID,
      runID: runID
    )
  }

  func inbound(updateID: Int64, chatID: Int64 = 42) -> InboundMessage {
    InboundMessage(
      updateID: updateID,
      sessionKey: SessionKey.telegramDM(chatID: chatID),
      chatID: chatID,
      userID: chatID,
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
      runID: env.runID,
      sessionID: env.sessionID,
      commit: SuspendedTurnCommit(
        assistantContent: "Let me save that.",
        toolCallsJSON: #"[{"id":"call-1","name":"file_write","arguments":"{}"}]"#,
        completedObservations: [],
        pending: PendingToolAction(toolCallID: "call-1", recorded: recorded),
        ownerUserID: 42,
        nonce: ApprovalNonce.generate(),
        promptChunks: [
          OutboxChunk(
            stepIndex: 0,
            chatID: 42,
            payload: "prompt",
            payloadHash: "h",
            replyMarkup: markup
          ),
        ],
        setTainted: false,
        setPrivateData: false,
        expiresTs: now.addingTimeInterval(3600)
      ),
      now: now
    )
    return receipt.approvalID
  }
}
