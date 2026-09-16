import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawGateway

struct GroupApprovalFixture {
  static let chatID: Int64 = -100_123
  static let requesterID: Int64 = 41
  static let participantID: Int64 = 42
  static let promptMessageID: Int64 = 900
  static let policyVersion = "group-coder-policy"
  static let now = Date(timeIntervalSince1970: 1_000_000)

  let queue: DatabaseQueue
  let runs: RunStoreGRDB
  let approvals: ApprovalStoreGRDB
  let approval: Approval

  init(reason: ApprovalReason = .coderSubmit, tool: String = CoderToolNames.submit) throws {
    queue = try TestDatabase.make()
    runs = RunStoreGRDB(writer: queue)
    approvals = ApprovalStoreGRDB(writer: queue)
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let receipt = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateID: 1,
        sessionKey: SessionKey.telegramTopic(chatID: Self.chatID, threadID: 77),
        chatID: Self.chatID,
        userID: Self.requesterID,
        text: "Ask Coder to inspect this repository.",
        isEdited: false,
        telegramMessageID: 88,
        ts: Self.now
      )
    )
    let runID = try #require(receipt.runID)
    let sessionID = try #require(receipt.sessionID)
    _ = try runs.pickUp(runID: runID, policyVersion: Self.policyVersion, now: Self.now)
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
      runID: runID,
      sessionID: sessionID,
      commit: SuspendedTurnCommit(
        assistantContent: "Coder can inspect this repository.",
        toolCallsJSON: try #require(
          ToolCallCoding.encode([ToolCall(id: "coder-call", name: tool, argumentsJSON: args)])
        ),
        completedObservations: [],
        pending: PendingToolAction(toolCallID: "coder-call", recorded: recorded),
        ownerUserID: Self.chatID,
        nonce: nonce,
        promptChunks: [
          OutboxChunk(
            stepIndex: 0,
            chatID: Self.chatID,
            payload: prompt,
            payloadHash: ContentHash.fnv1a(prompt),
            replyMarkup: ApprovalKeyboard.markup(nonce: nonce)
          ),
        ],
        setTainted: false,
        setPrivateData: false,
        expiresTs: Self.now.addingTimeInterval(3_600)
      ),
      now: Self.now
    )
    let outbox = OutboxStoreGRDB(writer: queue)
    let promptRow = try #require(
      try outbox.pendingOutbound().first {
        $0.runID == runID && $0.stepIndex == 0
      }
    )
    try outbox.markSent(
      deliveryKey: promptRow.deliveryKey,
      telegramMessageID: Self.promptMessageID,
      now: Self.now
    )
    approval = try #require(try approvals.approval(id: suspended.approvalID))
  }

  func callback(
    from userID: Int64 = participantID,
    chatID: Int64? = chatID,
    messageID: Int64? = promptMessageID,
    approve: Bool = true
  ) -> RawCallback {
    RawCallback(
      callbackID: "callback-\(userID)",
      fromUserID: userID,
      chatID: chatID,
      messageID: messageID,
      data: ApprovalKeyboard.callbackData(
        nonce: approval.nonce,
        verdict: approve ? ApprovalKeyboard.approveVerdict : ApprovalKeyboard.denyVerdict
      )
    )
  }
}
