import ClawCore
import ClawData
import ClawGateway
import ClawTestSupport
import Foundation
import GRDB
import Testing

struct CoderServiceFixture: Sendable {
  static let executionPolicyID = PolicyFingerprint.hash(parts: ["Coder service fixture"])

  let queue: DatabaseQueue
  let store: CoderJobStoreGRDB
  let backend: ScriptedCoderBackend
  let preparer: CoderPreparationStub
  let inspector: CoderInspectionStub
  let service: CoderService
  let ownerContext: ToolExecutionContext
  let prepared: CoderPreparedRequest
  let jobFinished: AsyncGate
  let root: URL

  init(
    limit: Int = 1,
    scripts: [ScriptedCoderBackend.Invocation] = [],
    inspection: CoderRecoveryObservation = .stopped,
    redactor: @escaping @Sendable (String) -> String = { text in
      text
    }
  ) throws {
    queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    store = CoderJobStoreGRDB(writer: queue)
    root = try makeTemporaryRoot(prefix: "coder-service")
    prepared = Self.request(index: 1)
    preparer = CoderPreparationStub()
    inspector = CoderInspectionStub(observation: inspection)
    backend = ScriptedCoderBackend(
      invocations: scripts.isEmpty ? [.init(result: Self.result())] : scripts
    )
    jobFinished = AsyncGate()
    ownerContext = try Self.context(queue: queue, prepared: prepared, index: 1)
    service = Self.makeService(
      store: store,
      backend: backend,
      preparer: preparer,
      inspector: inspector,
      root: root,
      limit: limit,
      finished: jobFinished,
      redactor: redactor
    )
  }

  func submitFirst() async throws -> CoderJob {
    try await service.submit(prepared, context: ownerContext)
  }

  func submitAnotherApprovedOrigin(index: Int64 = 2) async -> Result<CoderJob, CoderError> {
    do {
      let prepared = Self.request(index: index)
      let context = try Self.context(queue: queue, prepared: prepared, index: index)
      return .success(try await service.submit(prepared, context: context))
    } catch let error as CoderError {
      return .failure(error)
    } catch {
      Issue.record(error)
      return .failure(.unavailable("Fixture origin failed"))
    }
  }

  func reports() throws -> [OutboxRow] {
    try OutboxStoreGRDB(writer: queue).pendingOutbound().filter { row in
      row.approvalId == nil
    }
  }

  func cleanup() {
    backend.releaseAll()
    try? FileManager.default.removeItem(at: root)
  }

  func restartedService(
    redactor: @escaping @Sendable (String) -> String = { text in
      text
    }
  ) -> CoderService {
    Self.makeService(
      store: store,
      backend: backend,
      preparer: preparer,
      inspector: inspector,
      root: root,
      limit: 4,
      finished: jobFinished,
      redactor: redactor
    )
  }

  static func makeService(
    store: CoderJobStoreGRDB,
    backend: ScriptedCoderBackend,
    preparer: CoderPreparationStub,
    inspector: CoderInspectionStub,
    root: URL,
    limit: Int,
    finished: AsyncGate,
    redactor: @escaping @Sendable (String) -> String
  ) -> CoderService {
    CoderService(
      store: store,
      backend: backend,
      preparer: preparer,
      inspector: inspector,
      config: CoderConfig(
        enabled: true,
        maxConcurrentJobs: limit,
        jobTimeoutSeconds: 600,
        executable: CoderConfig.Defaults.executable,
        profile: nil,
        configHome: nil
      ),
      jobRoot: root.path,
      executionPolicyID: CoderServiceFixture.executionPolicyID,
      redact: redactor,
      notifyOutbox: { finished.open() }
    )
  }

  static func context(
    queue: DatabaseQueue,
    prepared: CoderPreparedRequest,
    index: Int64,
    ownerID: Int64 = 7
  ) throws -> ToolExecutionContext {
    let origin = try CoderApprovedOriginFixture.make(
      queue: queue,
      updateID: index,
      prepared: prepared,
      now: Date(timeIntervalSince1970: 1_800_000_000),
      ownerID: ownerID
    )
    let outbox = OutboxStoreGRDB(writer: queue)
    for row in try outbox.pendingOutbound() where row.runId == origin.runID {
      try outbox.markSent(
        runId: row.runId,
        stepIndex: row.stepIndex,
        telegramMessageId: 12,
        now: Date(timeIntervalSince1970: 1_800_000_000)
      )
    }
    return ToolExecutionContext(
      runId: origin.runID,
      sessionId: origin.sessionID,
      chatId: origin.chatID,
      requesterUserId: origin.requesterUserID,
      origin: .interactive,
      mode: .direct,
      toolCallId: origin.toolCallID,
      approvalId: origin.approvalID
    )
  }

  static func request(
    index: Int64 = 1,
    policy: String = CoderServiceFixture.executionPolicyID
  ) -> CoderPreparedRequest {
    let path = "/fixture/repository-\(index)"
    return CoderPreparedRequest(
      request: CoderRequest(
        source: .local(path: path),
        task: "Fix retry handling",
        workspace: .inPlace,
        startRef: nil,
        deliverable: .localChanges,
        baseBranch: nil,
        instructions: nil,
        publishExistingChanges: false
      ),
      canonicalSource: path,
      checkoutPath: path,
      commonGitDirectory: path + "/.git",
      executionPolicyID: policy,
      publicationRepository: nil
    )
  }

  static func result(
    state: CoderJobState = .succeeded,
    failure: CoderFailure? = nil
  ) -> CoderResult {
    CoderResult(
      state: state,
      summary: "Updated retry handling",
      workspacePath: "/fixture/output",
      startingCommit: "abc123",
      baselineObserved: true,
      changedFiles: ["Retry.swift"],
      branch: "fix/retry",
      commit: "def456",
      publication: .absent,
      reportedChecks: ["swift test"],
      reportedUsage: nil,
      commitAuthor: nil,
      githubActor: nil,
      failure: failure
    )
  }
}

actor CoderPreparationStub: CoderRequestPreparing {
  let entered = AsyncGate()
  let proceed = AsyncGate()
  var changedIdentity = false
  var hold = false

  func configure(changedIdentity: Bool = false, hold: Bool = false) {
    self.changedIdentity = changedIdentity
    self.hold = hold
  }

  func prepare(_ request: CoderRequest) async throws -> CoderPreparedRequest {
    entered.open()
    if hold { await proceed.waitIgnoringCancellation() }
    guard case .local(let path) = request.source else {
      throw CoderError.invalidRequest("Fixture requires a local source")
    }
    return CoderPreparedRequest(
      request: request,
      canonicalSource: path,
      checkoutPath: path,
      commonGitDirectory: path + (changedIdentity ? "/changed.git" : "/.git"),
      executionPolicyID: CoderServiceFixture.executionPolicyID,
      publicationRepository: nil
    )
  }
}

actor CoderInspectionStub: CoderProcessInspecting {
  nonisolated let entered = AsyncGate()
  nonisolated let proceed = AsyncGate()
  var hold = false

  func holdInspection() { hold = true }

  var observation: CoderRecoveryObservation

  init(observation: CoderRecoveryObservation) { self.observation = observation }

  func set(_ observation: CoderRecoveryObservation) { self.observation = observation }

  func inspect(_ receipt: CoderProcessReceipt) async -> CoderRecoveryObservation {
    entered.open()
    if hold { await proceed.waitIgnoringCancellation() }
    return observation
  }
}
