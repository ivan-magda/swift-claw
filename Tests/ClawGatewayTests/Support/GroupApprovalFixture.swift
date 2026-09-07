import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawGateway

struct GroupApprovalFixture {
  static let chatId: Int64 = -100_123
  static let requesterId: Int64 = 41
  static let participantId: Int64 = 42
  static let promptMessageId: Int64 = 900
  static let policyVersion = "group-coder-policy"
  static let now = Date(timeIntervalSince1970: 1_000_000)

  let queue: DatabaseQueue
  let runs: RunStoreGRDB
  let approvals: ApprovalStoreGRDB
  let approval: Approval

  init(reason: ApprovalReason = .coderSubmit, tool: String = CoderToolNames.submit) throws {
    queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    runs = RunStoreGRDB(writer: queue)
    approvals = ApprovalStoreGRDB(writer: queue)
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let receipt = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateId: 1,
        sessionKey: SessionKey.telegramTopic(chatId: Self.chatId, threadId: 77),
        chatId: Self.chatId,
        userId: Self.requesterId,
        text: "Ask Coder to inspect this repository.",
        isEdited: false,
        telegramMessageId: 88,
        ts: Self.now
      )
    )
    let runId = try #require(receipt.runId)
    let sessionId = try #require(receipt.sessionId)
    _ = try runs.pickUp(runId: runId, policyVersion: Self.policyVersion, now: Self.now)
    let args = #"{"task":"Inspect the repository"}"#
    let recorded = RecordedToolAction(
      tool: tool,
      canonicalArgsJSON: args,
      argsHash: ApprovalArgsHash.sha256Hex(args),
      canonicalTarget: "/workspace/project",
      reason: reason,
      presentation: ToolApprovalPresentation(
        blastRadius: "Native Coder delegation",
        contentPreview: nil,
        warnings: []
      )
    )
    let prompt = "Review the concrete Coder request."
    let nonce = ApprovalNonce.generate()
    let suspended = try runs.commitSuspendedTurn(
      runId: runId,
      sessionId: sessionId,
      commit: SuspendedTurnCommit(
        assistantContent: "Coder can inspect this repository.",
        toolCallsJSON: try #require(
          ToolCallCoding.encode([ToolCall(id: "coder-call", name: tool, argumentsJSON: args)])
        ),
        completedObservations: [],
        pending: PendingToolAction(toolCallId: "coder-call", recorded: recorded),
        ownerUserId: Self.chatId,
        nonce: nonce,
        promptChunks: [
          OutboxChunk(
            stepIndex: 0,
            chatId: Self.chatId,
            payload: prompt,
            payloadHash: ContentHash.fnv1a(prompt),
            replyMarkup: ApprovalKeyboard.markup(nonce: nonce)
          )
        ],
        setTainted: false,
        setPrivateData: false,
        expiresTs: Self.now.addingTimeInterval(3_600)
      ),
      now: Self.now
    )
    try OutboxStoreGRDB(writer: queue).markSent(
      runId: runId,
      stepIndex: 0,
      telegramMessageId: Self.promptMessageId,
      now: Self.now
    )
    approval = try #require(try approvals.approval(id: suspended.approvalId))
  }

  func callback(
    from userId: Int64 = participantId,
    chatId: Int64? = chatId,
    messageId: Int64? = promptMessageId,
    approve: Bool = true
  ) -> RawCallback {
    RawCallback(
      callbackId: "callback-\(userId)",
      fromUserId: userId,
      chatId: chatId,
      messageId: messageId,
      data: ApprovalKeyboard.callbackData(
        nonce: approval.nonce,
        verdict: approve ? ApprovalKeyboard.approveVerdict : ApprovalKeyboard.denyVerdict
      )
    )
  }
}
