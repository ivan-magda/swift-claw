import ClawCore
import ClawData
import Foundation
import GRDB

/// A real participant message and approved conference action, not invented foreign-key IDs.
public enum ConferenceApprovedOriginFixture {
  public static func make(
    queue: DatabaseQueue,
    prepared: PreparedConferenceSubmission,
    userID: Int64 = 101,
    updateID: Int64 = 1,
    now: Date = Date()
  ) throws -> ConferenceApprovedOrigin {
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let runs = RunStoreGRDB(writer: queue)
    let approvals = ApprovalStoreGRDB(writer: queue)
    let policy = PolicyFingerprint.combined(
      staticSubhash: "conference-test-policy",
      promptMaterials: ["Conference approval fixture"]
    )
    let claim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateId: updateID,
        sessionKey: SessionKey.telegramDM(chatId: userID),
        chatId: userID,
        userId: userID,
        text: prepared.answer,
        isEdited: false,
        telegramMessageId: updateID,
        ts: now
      )
    )
    let runID = try required(claim.runId)
    let sessionID = try required(claim.sessionId)
    _ = try runs.pickUp(runId: runID, policyVersion: policy, now: now)
    let toolCallID = "conference-submit-\(updateID)"
    let canonical = try required(CanonicalJSON.encode(prepared))
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
    let arguments = try required(CanonicalJSON.encode(JSONValue.object([
      "answer": .string(prepared.answer)
    ])))
    let calls = try required(ToolCallCoding.encode([
      ToolCall(id: toolCallID, name: ConferenceToolNames.submit, argumentsJSON: arguments)
    ]))
    let receipt = try runs.commitSuspendedTurn(
      runId: runID,
      sessionId: sessionID,
      commit: SuspendedTurnCommit(
        assistantContent: "Confirm your conference proposal.",
        toolCallsJSON: calls,
        completedObservations: [],
        pending: PendingToolAction(toolCallId: toolCallID, recorded: recorded),
        ownerUserId: userID,
        nonce: ApprovalNonce.generate(),
        promptChunks: [
          OutboxChunk(
            stepIndex: 0,
            chatId: userID,
            payload: prepared.answer,
            payloadHash: ContentHash.fnv1a(prepared.answer)
          )
        ],
        setTainted: false,
        setPrivateData: false,
        expiresTs: now.addingTimeInterval(3_600)
      ),
      now: now
    )
    let resolution = try approvals.approve(
      id: receipt.approvalId,
      currentPolicyVersion: policy,
      actor: ApprovalResolutionActor(actor: .owner, userId: userID),
      now: now
    )
    guard case .approved(let approval) = resolution else {
      throw StoreError.unexpected("Conference fixture approval was not granted")
    }
    let execution = try runs.claimApprovedExecution(
      runId: approval.runId,
      observationMessageId: approval.observationMessageId,
      notResumableObservationContent: "The submission was stopped before admission.",
      now: now
    )
    guard execution == .committed else {
      throw StoreError.unexpected("Conference fixture could not claim approved execution")
    }
    return ConferenceApprovedOrigin(
      runID: runID,
      sessionID: sessionID,
      chatID: userID,
      requesterUserID: userID,
      mode: .direct,
      toolCallID: toolCallID,
      approvalID: approval.id
    )
  }

  private static func required<Value>(_ value: Value?) throws -> Value {
    guard let value else {
      throw StoreError.unexpected("Conference fixture is missing a required value")
    }
    return value
  }
}
