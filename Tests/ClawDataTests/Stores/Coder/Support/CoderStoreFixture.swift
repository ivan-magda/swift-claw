import ClawCore
import ClawTestSupport
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
    self.origin = try CoderApprovedOriginFixture.make(
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

// MARK: - Prepared Request

private extension CoderStoreFixture {
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
