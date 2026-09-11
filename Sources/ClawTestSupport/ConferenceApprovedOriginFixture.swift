import ClawCore
import Foundation
import GRDB

/// A real participant message and approved conference action, not invented foreign-key IDs.
public enum ConferenceApprovedOriginFixture {
  public static let chatID: Int64 = -100_123
  public static let threadID: Int64 = 77

  public static func make(
    queue: DatabaseQueue,
    prepared: PreparedConferenceSubmission,
    userID: Int64 = 101,
    updateID: Int64 = 1,
    threadID: Int64 = Self.threadID,
    now: Date = Date()
  ) throws -> ConferenceApprovedOrigin {
    let policy = PolicyFingerprint.combined(
      staticSubhash: "conference-test-policy",
      promptMaterials: ["Conference approval fixture"]
    )
    let toolCallID = "conference-submit-\(updateID)"
    let canonical = try ApprovedExecutionFixture.required(CanonicalJSON.encode(prepared))
    let item = prepared.caseSnapshot
    let recorded = RecordedToolAction(
      tool: ConferenceToolNames.submit,
      canonicalArgsJSON: canonical,
      argsHash: ApprovalArgsHash.sha256Hex(canonical),
      canonicalTarget: "conference:\(item.id):\(item.repositoryURL)@\(item.baselineRef)",
      reason: .conferenceSubmit,
      presentation: ToolApprovalPresentation(
        blastRadius: "Implement the proposal and publish a draft PR.",
        contentPreview: prepared.answer,
        warnings: []
      )
    )
    let arguments = try ApprovedExecutionFixture.required(
      CanonicalJSON.encode(
        JSONValue.object([
          "answer": .string(prepared.answer)
        ])
      )
    )
    let calls = try ApprovedExecutionFixture.required(
      ToolCallCoding.encode([
        ToolCall(id: toolCallID, name: ConferenceToolNames.submit, argumentsJSON: arguments)
      ])
    )
    let approval = try ApprovedExecutionFixture.claim(
      queue: queue,
      inbound: InboundMessage(
        updateId: updateID,
        sessionKey: SessionKey.telegramTopic(chatId: chatID, threadId: threadID),
        chatId: chatID,
        userId: userID,
        text: ChatMode.group.transcriptText(
          prepared.answer,
          author: TranscriptAuthor(displayName: "Participant: \nName", userId: userID)
        ),
        isEdited: false,
        telegramMessageId: updateID,
        ts: now
      ),
      policyVersion: policy,
      commit: SuspendedTurnCommit(
        assistantContent: "Confirm your conference proposal.",
        toolCallsJSON: calls,
        completedObservations: [],
        pending: PendingToolAction(toolCallId: toolCallID, recorded: recorded),
        ownerUserId: chatID,
        nonce: ApprovalNonce.generate(),
        promptChunks: [
          OutboxChunk(
            stepIndex: 0,
            chatId: chatID,
            payload: prepared.answer,
            payloadHash: ContentHash.fnv1a(prepared.answer)
          )
        ],
        setTainted: false,
        setPrivateData: false,
        expiresTs: now.addingTimeInterval(3_600)
      ),
      actor: ApprovalResolutionActor(actor: .groupMember, userId: userID),
      now: now
    )
    return ConferenceApprovedOrigin(
      runID: approval.runId,
      sessionID: approval.sessionId,
      chatID: chatID,
      requesterUserID: userID,
      mode: .group,
      toolCallID: approval.toolCallId,
      approvalID: approval.id
    )
  }
}
