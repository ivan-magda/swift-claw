import ClawCore
import ClawData
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
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let runs = RunStoreGRDB(writer: queue)
    let approvals = ApprovalStoreGRDB(writer: queue)
    let toolCallID = "coder-submit-fixture-call-\(updateID)"
    let policyVersion = PolicyFingerprint.combined(
      staticSubhash: prepared.executionPolicyID,
      promptMaterials: ["Coder store fixture"]
    )
    let claim = try sessions.claimAndPersistInbound(
      inbound(
        prepared: prepared,
        updateID: updateID,
        ownerID: ownerID,
        groupChatID: groupChatID,
        threadID: threadID,
        now: now
      )
    )
    let runID = try required(claim.runID)
    let sessionID = try required(claim.sessionID)
    let pickedUpOrigin = try required(
      try runs.pickUp(runID: runID, policyVersion: policyVersion, now: now)
    )
    guard pickedUpOrigin == .interactive else {
      throw StoreError.unexpected("Coder fixture did not create an interactive run")
    }
    let receipt = try runs.commitSuspendedTurn(
      runID: runID,
      sessionID: sessionID,
      commit: approvalCommit(prepared: prepared, chatID: chatID, toolCallID: toolCallID, now: now),
      now: now
    )
    let resolution = try approvals.approve(
      id: receipt.approvalID,
      currentPolicyVersion: policyVersion,
      actor: ApprovalResolutionActor(
        actor: groupChatID == nil ? .owner : .groupMember,
        userID: ownerID
      ),
      now: now
    )
    guard case .approved(let approval) = resolution else {
      throw StoreError.unexpected("Coder fixture approval was not granted")
    }
    let executionClaim = try runs.claimApprovedExecution(
      runID: approval.runID,
      observationMessageID: approval.observationMessageID,
      notResumableObservationContent: "The task was stopped before admission.",
      now: now
    )
    guard executionClaim == .committed else {
      throw StoreError.unexpected("Coder fixture could not claim its approved execution")
    }
    return CoderOrigin(
      runID: approval.runID,
      sessionID: approval.sessionID,
      requesterUserID: ownerID,
      chatID: chatID,
      toolCallID: approval.toolCallID,
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
        SessionKey.telegramTopic(chatID: chatID, threadID: threadID)
      }
      ?? SessionKey.telegramDM(chatID: ownerID)
    return InboundMessage(
      updateID: updateID,
      sessionKey: sessionKey,
      chatID: groupChatID ?? ownerID,
      userID: ownerID,
      text: "Use Coder for \(prepared.canonicalSource).",
      isEdited: false,
      telegramMessageID: 11,
      ts: now
    )
  }

  static func approvalCommit(
    prepared: CoderPreparedRequest,
    chatID: Int64,
    toolCallID: String,
    now: Date
  ) throws -> SuspendedTurnCommit {
    let canonicalArgsJSON = try required(CanonicalJSON.encode(prepared))
    let task = prepared.request.task ?? "Resolve the issue"
    let blastRadius =
      "\(prepared.request.workspace.rawValue); local changes; " + "native Codex with network access"
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
      pending: PendingToolAction(toolCallID: toolCallID, recorded: recorded),
      ownerUserID: chatID,
      nonce: ApprovalNonce.generate(),
      promptChunks: [
        OutboxChunk(
          stepIndex: 0,
          chatID: chatID,
          payload: prompt,
          payloadHash: ContentHash.fnv1a(prompt)
        ),
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
    let sourceJSON = try required(CanonicalJSON.encode(request.source))
    let sourceArgument = try required(JSONValue.parse(sourceJSON))
    let proposedArguments = JSONValue.object([
      "source": sourceArgument,
      "task": .string(request.task ?? "Resolve the issue"),
      "workspace": .string(request.workspace.rawValue),
      "deliverable": .string(request.deliverable.rawValue),
      "publish_existing_changes": .bool(request.publishExistingChanges),
    ])
    let proposedArgsJSON = try required(CanonicalJSON.encode(proposedArguments))
    return try required(
      ToolCallCoding.encode([
        ToolCall(id: toolCallID, name: CoderToolNames.submit, argumentsJSON: proposedArgsJSON),
      ])
    )
  }

  static func required<T>(_ value: T?) throws -> T {
    guard let value else {
      throw StoreError.unexpected("Coder approval fixture is missing a required value")
    }
    return value
  }
}
