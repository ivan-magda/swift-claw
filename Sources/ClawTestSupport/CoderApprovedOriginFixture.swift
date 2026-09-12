import ClawCore
import Foundation
import GRDB

public enum CoderApprovedOriginFixture {
  public static func make(
    queue: DatabaseQueue,
    updateID: Int64,
    prepared: CoderPreparedRequest,
    now: Date,
    ownerID: Int64 = 7,
    groupChatID: Int64? = nil,
    threadID: Int64? = nil
  ) throws -> CoderOrigin {
    let chatID = groupChatID ?? ownerID
    let toolCallID = "coder-submit-fixture-call-\(updateID)"
    let policyVersion = PolicyFingerprint.combined(
      staticSubhash: prepared.executionPolicyID,
      promptMaterials: ["Coder store fixture"]
    )
    let approval = try ApprovedExecutionFixture.claim(
      queue: queue,
      inbound: inbound(
        prepared: prepared,
        updateID: updateID,
        ownerID: ownerID,
        groupChatID: groupChatID,
        threadID: threadID,
        now: now
      ),
      policyVersion: policyVersion,
      commit: approvalCommit(
        prepared: prepared,
        chatID: chatID,
        toolCallID: toolCallID,
        now: now
      ),
      actor: ApprovalResolutionActor(
        actor: groupChatID == nil ? .owner : .groupMember,
        userId: ownerID
      ),
      now: now
    )
    return CoderOrigin(
      runID: approval.runId,
      sessionID: approval.sessionId,
      requesterUserID: ownerID,
      chatID: chatID,
      toolCallID: approval.toolCallId,
      approvalID: approval.id
    )
  }
}

// MARK: - Approved Turn Construction

private extension CoderApprovedOriginFixture {
  static func inbound(
    prepared: CoderPreparedRequest,
    updateID: Int64,
    ownerID: Int64,
    groupChatID: Int64?,
    threadID: Int64?,
    now: Date
  ) -> InboundMessage {
    let sessionKey =
      groupChatID.map { chatID in
        SessionKey.telegramTopic(chatId: chatID, threadId: threadID)
      } ?? SessionKey.telegramDM(chatId: ownerID)
    return InboundMessage(
      updateId: updateID,
      sessionKey: sessionKey,
      chatId: groupChatID ?? ownerID,
      userId: ownerID,
      text: "Use Coder for \(prepared.canonicalSource).",
      isEdited: false,
      telegramMessageId: 11,
      ts: now
    )
  }

  static func approvalCommit(
    prepared: CoderPreparedRequest,
    chatID: Int64,
    toolCallID: String,
    now: Date
  ) throws -> SuspendedTurnCommit {
    let canonicalArgsJSON = try ApprovedExecutionFixture.required(CanonicalJSON.encode(prepared))
    let task = prepared.request.task ?? "Resolve the issue"
    let blastRadius =
      "\(prepared.request.workspace.rawValue); local changes; "
      + "native Codex with network access"
    let recorded = RecordedToolAction(
      tool: CoderToolNames.submit,
      canonicalArgsJSON: canonicalArgsJSON,
      argsHash: ApprovalArgsHash.sha256Hex(canonicalArgsJSON),
      canonicalTarget: prepared.canonicalSource,
      reason: .coderSubmit,
      presentation: ToolApprovalPresentation(
        blastRadius: blastRadius,
        contentPreview: task,
        warnings: []
      )
    )
    let prompt = "Approve Coder for \(prepared.canonicalSource): \(task)"
    return SuspendedTurnCommit(
      assistantContent: "I can delegate this repository task to Coder.",
      toolCallsJSON: try proposedToolCalls(prepared: prepared, toolCallID: toolCallID),
      completedObservations: [],
      pending: PendingToolAction(toolCallId: toolCallID, recorded: recorded),
      ownerUserId: chatID,
      nonce: ApprovalNonce.generate(),
      promptChunks: [
        OutboxChunk(
          stepIndex: 0,
          chatId: chatID,
          payload: prompt,
          payloadHash: ContentHash.fnv1a(prompt)
        )
      ],
      setTainted: false,
      setPrivateData: false,
      expiresTs: now.addingTimeInterval(3_600)
    )
  }

  static func proposedToolCalls(
    prepared: CoderPreparedRequest,
    toolCallID: String
  ) throws -> String {
    let request = prepared.request
    let sourceJSON = try ApprovedExecutionFixture.required(CanonicalJSON.encode(request.source))
    let sourceArgument = try ApprovedExecutionFixture.required(JSONValue.parse(sourceJSON))
    let proposedArguments = JSONValue.object([
      "source": sourceArgument,
      "task": .string(request.task ?? "Resolve the issue"),
      "workspace": .string(request.workspace.rawValue),
      "deliverable": .string(request.deliverable.rawValue),
      "publish_existing_changes": .bool(request.publishExistingChanges),
    ])
    let proposedArgsJSON = try ApprovedExecutionFixture.required(
      CanonicalJSON.encode(proposedArguments)
    )
    return try ApprovedExecutionFixture.required(
      ToolCallCoding.encode([
        ToolCall(id: toolCallID, name: CoderToolNames.submit, argumentsJSON: proposedArgsJSON)
      ])
    )
  }
}
