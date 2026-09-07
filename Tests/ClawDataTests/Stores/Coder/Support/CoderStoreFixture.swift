import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

struct CoderStoreFixture: Sendable {
  let queue: DatabaseQueue
  let store: CoderJobStoreGRDB
  let origin: CoderOrigin
  let prepared: CoderPreparedRequest
  let now: Date

  init(
    queue suppliedQueue: DatabaseQueue? = nil,
    updateID: Int64 = 1,
    prepared suppliedPrepared: CoderPreparedRequest? = nil,
    schemaVersion: String? = nil
  ) throws {
    let queue = try suppliedQueue ?? ClawDatabase.makeInMemoryQueue()
    if let schemaVersion {
      try ClawDatabase.migrator.migrate(queue, upTo: schemaVersion)
    } else {
      try ClawDatabase.migrate(queue)
    }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let prepared = try suppliedPrepared ?? Self.separateRequest()
    self.queue = queue
    self.store = CoderJobStoreGRDB(writer: queue)
    self.prepared = prepared
    self.now = now
    self.origin = try Self.approvedOrigin(
      queue: queue,
      updateID: updateID,
      prepared: prepared,
      now: now
    )
  }

  func admit(id: UUID, limit: Int) throws -> CoderAdmission {
    try store.admit(
      id: id,
      prepared: prepared,
      origin: origin,
      maxConcurrentJobs: limit,
      now: now
    )
  }
}

// MARK: - Real Approval Origin

private extension CoderStoreFixture {
  static func approvedOrigin(
    queue: DatabaseQueue,
    updateID: Int64,
    prepared: CoderPreparedRequest,
    now: Date
  ) throws -> CoderOrigin {
    let sessions = SessionMessageStoreGRDB(writer: queue)
    let runs = RunStoreGRDB(writer: queue)
    let approvals = ApprovalStoreGRDB(writer: queue)
    let ownerID: Int64 = 7
    let toolCallID = "coder-submit-fixture-call-\(updateID)"
    let policyVersion = PolicyFingerprint.combined(
      staticSubhash: prepared.executionPolicyID,
      promptMaterials: ["Coder store fixture"]
    )
    let claim = try sessions.claimAndPersistInbound(
      InboundMessage(
        updateId: updateID,
        sessionKey: SessionKey.telegramDM(chatId: ownerID),
        chatId: ownerID,
        userId: ownerID,
        text: "Use Coder for \(prepared.canonicalSource).",
        isEdited: false,
        telegramMessageId: 11,
        ts: now
      )
    )
    let runID = try #require(claim.runId)
    let sessionID = try #require(claim.sessionId)
    let pickedUpOrigin = try #require(
      try runs.pickUp(runId: runID, policyVersion: policyVersion, now: now)
    )
    guard pickedUpOrigin == .interactive else {
      throw StoreError.unexpected("Coder fixture did not create an interactive run")
    }
    let receipt = try runs.commitSuspendedTurn(
      runId: runID,
      sessionId: sessionID,
      commit: approvalCommit(
        prepared: prepared,
        ownerID: ownerID,
        toolCallID: toolCallID,
        now: now
      ),
      now: now
    )
    let resolution = try approvals.approve(
      id: receipt.approvalId,
      currentPolicyVersion: policyVersion,
      now: now
    )
    guard case .approved(let approval) = resolution else {
      throw StoreError.unexpected("Coder fixture approval was not granted")
    }
    let executionClaim = try runs.claimApprovedExecution(
      runId: approval.runId,
      observationMessageId: approval.observationMessageId,
      notResumableObservationContent: "The task was stopped before admission.",
      now: now
    )
    guard executionClaim == .committed else {
      throw StoreError.unexpected("Coder fixture could not claim its approved execution")
    }
    return CoderOrigin(
      runID: approval.runId,
      sessionID: approval.sessionId,
      requesterUserID: approval.ownerUserId,
      chatID: approval.ownerUserId,
      toolCallID: approval.toolCallId,
      approvalID: approval.id
    )
  }

  static func approvalCommit(
    prepared: CoderPreparedRequest,
    ownerID: Int64,
    toolCallID: String,
    now: Date
  ) throws -> SuspendedTurnCommit {
    let canonicalArgsJSON = try #require(CanonicalJSON.encode(prepared))
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
      ownerUserId: ownerID,
      nonce: ApprovalNonce.generate(),
      promptChunks: [
        OutboxChunk(
          stepIndex: 0,
          chatId: ownerID,
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
    let sourceJSON = try #require(CanonicalJSON.encode(request.source))
    let sourceArgument = try #require(JSONValue.parse(sourceJSON))
    let proposedArguments = JSONValue.object([
      "source": sourceArgument,
      "task": .string(request.task ?? "Resolve the issue"),
      "workspace": .string(request.workspace.rawValue),
      "deliverable": .string(request.deliverable.rawValue),
      "publish_existing_changes": .bool(request.publishExistingChanges),
    ])
    let proposedArgsJSON = try #require(CanonicalJSON.encode(proposedArguments))
    return try #require(
      ToolCallCoding.encode([
        ToolCall(id: toolCallID, name: CoderToolNames.submit, argumentsJSON: proposedArgsJSON)
      ])
    )
  }

  static func separateRequest() throws -> CoderPreparedRequest {
    let sourceURL = "https://github.com/owner/project"
    let request = try CoderRequest(
      source: .githubRepository(url: sourceURL),
      task: "Correct the documented retry timeout.",
      workspace: .separate,
      startRef: nil,
      deliverable: .localChanges,
      baseBranch: nil,
      instructions: nil,
      publishExistingChanges: false
    ).validated()
    return CoderPreparedRequest(
      request: request,
      canonicalSource: sourceURL,
      checkoutPath: nil,
      commonGitDirectory: nil,
      executionPolicyID: PolicyFingerprint.hash(parts: ["coder-store-fixture-policy"]),
      publicationRepository: nil
    )
  }
}

// MARK: - Job Lifecycle Fixtures

extension CoderStoreFixture {
  func admittedID() throws -> UUID {
    let id = UUID()
    guard case .admitted = try admit(id: id, limit: 4) else {
      throw StoreError.unexpected("Fixture admission failed")
    }
    return id
  }

  static func result(state: CoderJobState = .succeeded) -> CoderResult {
    CoderResult(
      state: state,
      summary: "Updated retry timeout",
      workspacePath: nil,
      startingCommit: nil,
      baselineObserved: false,
      changedFiles: nil,
      branch: nil,
      commit: nil,
      publication: .absent,
      reportedChecks: [],
      reportedUsage: nil,
      commitAuthor: nil,
      githubActor: nil,
      failure: nil
    )
  }

  static func receipt(
    id: UUID = UUID(),
    phase: CoderProcessPhase = .prepare,
    launched: Bool = false
  ) -> CoderProcessReceipt {
    CoderProcessReceipt(
      launchID: id,
      phase: phase,
      hostBootID: "fixture-boot",
      pid: launched ? 123 : nil,
      pgid: launched ? 123 : nil,
      birthIdentity: launched ? "fixture-birth" : nil
    )
  }

  func complete(
    id: UUID,
    expected: CoderJobState = .running,
    state: CoderJobState = .succeeded,
    release: Bool = true
  ) throws -> CoderCompletionOutcome {
    try store.complete(
      id: id,
      expectedState: expected,
      result: Self.result(state: state),
      chunks: [
        OutboxChunk(
          stepIndex: 0,
          chatId: -999,
          payload: "Coder report",
          payloadHash: ContentHash.fnv1a("Coder report")
        )
      ],
      releaseReservation: release,
      now: now
    )
  }

  static func localRequest(
    checkout: String,
    common: String,
    workspace: CoderWorkspaceMode = .inPlace
  ) -> CoderPreparedRequest {
    CoderPreparedRequest(
      request: CoderRequest(
        source: .local(path: checkout),
        task: "Fix retries",
        workspace: workspace,
        startRef: nil,
        deliverable: .localChanges,
        baseBranch: nil,
        instructions: nil,
        publishExistingChanges: false
      ),
      canonicalSource: checkout,
      checkoutPath: checkout,
      commonGitDirectory: common,
      executionPolicyID: "fixture-policy",
      publicationRepository: nil
    )
  }
}
