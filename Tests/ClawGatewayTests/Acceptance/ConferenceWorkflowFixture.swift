import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import GRDB
import Logging
import Testing

@testable import ClawGateway

struct ConferenceWorkflowFixture {
  let queue: DatabaseQueue
  let store: ConferenceStoreGRDB
  let jobs: CoderJobStoreGRDB
  let outbox: OutboxStoreGRDB
  let coder: ConferenceTestCoder
  let publisher: ConferenceTestPublisher
  let service: ConferenceWorkflowService

  static let item = ConferenceCase(
    id: "day-1",
    title: "Accessibility regression",
    prompt: "A component release introduced accessibility regressions. Propose a solution.",
    repositoryURL: "https://github.com/wowlocal/crew18-sim",
    baselineRef: String(repeating: "b", count: 40),
    baseBranch: "challenge/day-1"
  )

  init(
    judge: @escaping @Sendable (PreparedConferenceSubmission) async throws -> Void = { _ in },
    busyAdmissions: Int = 0,
    publicationFailures: Int = 0,
    observedBaseline: String? = nil
  ) throws {
    queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    store = ConferenceStoreGRDB(writer: queue)
    jobs = CoderJobStoreGRDB(writer: queue)
    outbox = OutboxStoreGRDB(writer: queue)
    coder = ConferenceTestCoder(
      store: jobs,
      busyAdmissions: busyAdmissions,
      observedBaseline: observedBaseline
    )
    publisher = ConferenceTestPublisher(failures: publicationFailures)
    service = Self.service(
      item: Self.item,
      store: store,
      jobs: jobs,
      outbox: outbox,
      coder: coder,
      publisher: publisher,
      judge: judge
    )
  }

  func origin(answer: String, userID: Int64 = 101) throws -> ConferenceApprovedOrigin {
    try ConferenceApprovedOriginFixture.make(
      queue: queue,
      prepared: PreparedConferenceSubmission(caseSnapshot: Self.item, answer: answer),
      userID: userID,
      updateID: userID
    )
  }

  func restarted(activeCase: ConferenceCase = Self.item) -> ConferenceWorkflowService {
    Self.service(
      item: activeCase,
      store: store,
      jobs: jobs,
      outbox: outbox,
      coder: coder,
      publisher: publisher,
      judge: { _ in Issue.record("A queued submission must not be judged again after restart") }
    )
  }

  private static func service(
    item: ConferenceCase,
    store: ConferenceStoreGRDB,
    jobs: CoderJobStoreGRDB,
    outbox: OutboxStoreGRDB,
    coder: ConferenceTestCoder,
    publisher: ConferenceTestPublisher,
    judge: @escaping @Sendable (PreparedConferenceSubmission) async throws -> Void
  ) -> ConferenceWorkflowService {
    ConferenceWorkflowService(
      config: ConferenceConfig(enabled: true, activeCase: item, expectedGitHubActor: "crew18-bot"),
      prepareSource: { "/conference/source/\($0.id)" },
      validateSubmission: judge,
      store: store,
      coder: coder,
      coderJobs: jobs,
      publisher: publisher,
      outbox: outbox,
      notifyOutbox: {},
      logger: Logger(label: "conference-acceptance")
    )
  }

  func finish(
    _ id: UUID,
    using service: ConferenceWorkflowService? = nil
  ) async throws -> ConferenceSubmission {
    let service = service ?? self.service
    let runner = Task { try await service.run() }
    do {
      let finished = try await pollUntilTrue {
        guard let row = try store.submission(id: id) else {
          return false
        }
        return row.state.isTerminal && row.notificationEnqueued
      }
      runner.cancel()
      _ = await runner.result
      try #require(finished)
      return try #require(try store.submission(id: id))
    } catch {
      runner.cancel()
      _ = await runner.result
      throw error
    }
  }
}

actor ConferenceTestCoder: CoderServing {
  private let store: CoderJobStoreGRDB
  private var busyAdmissions: Int
  private let observedBaseline: String?
  private(set) var admissions = 0
  private(set) var requests: [CoderRequest] = []

  init(store: CoderJobStoreGRDB, busyAdmissions: Int, observedBaseline: String?) {
    self.store = store
    self.busyAdmissions = busyAdmissions
    self.observedBaseline = observedBaseline
  }

  func prepare(_ request: CoderRequest) async throws -> CoderPreparedRequest {
    requests.append(request)
    guard case .local(let path) = request.source else {
      throw CoderError.invalidRequest("Expected a supervisor-prepared local baseline")
    }
    return CoderPreparedRequest(
      request: request,
      canonicalSource: path,
      checkoutPath: path,
      commonGitDirectory: "\(path)/.git",
      executionPolicyID: "conference-test-policy",
      publicationRepository: nil
    )
  }

  func submit(
    _ prepared: CoderPreparedRequest,
    context: ToolExecutionContext
  ) async throws -> CoderJob {
    if busyAdmissions > 0 {
      busyAdmissions -= 1
      throw CoderError.busy
    }
    let admission = try store.admit(
      id: UUID(),
      prepared: prepared,
      origin: CoderOrigin(
        runID: context.runId,
        sessionID: context.sessionId,
        requesterUserID: try #require(context.requesterUserId),
        chatID: context.chatId,
        toolCallID: context.toolCallId,
        approvalID: try #require(context.approvalId)
      ),
      maxConcurrentJobs: 1,
      now: Date()
    )
    switch admission {
    case .existing(let job):
      return job
    case .admitted(let job):
      admissions += 1
      _ = try store.complete(
        id: job.id,
        expectedState: job.state,
        result: CoderResult(
          state: .succeeded,
          summary: "Implemented the exact proposal",
          workspacePath: "/conference/workspace",
          startingCommit: observedBaseline ?? prepared.request.startRef,
          baselineObserved: true,
          changedFiles: ["Sources/Feature.swift"],
          branch: nil,
          commit: String(repeating: "c", count: 40),
          publication: .absent,
          reportedChecks: ["fixture check passed"],
          reportedUsage: nil,
          commitAuthor: "Conference Coder",
          githubActor: nil,
          failure: nil
        ),
        chunks: [],
        releaseReservation: true,
        now: Date()
      )
      return job
    case .busy: throw CoderError.busy
    case .workspaceBusy: throw CoderError.workspaceBusy
    case .recoveryRequired: throw CoderError.recoveryRequired
    }
  }

  func status(id: UUID, context: ToolExecutionContext) async throws -> CoderJob {
    try #require(try store.job(id: id))
  }

  func cancel(id: UUID, context: ToolExecutionContext) async throws -> CoderJob {
    throw CoderError.unavailable("Unused fixture operation")
  }
}

actor ConferenceTestPublisher: ConferencePublishing {
  private var failures: Int
  private(set) var attempts = 0
  private(set) var lastRequest: ConferencePublicationRequest?

  init(failures: Int) {
    self.failures = failures
  }

  func publish(_ request: ConferencePublicationRequest) async throws -> ConferencePublication {
    attempts += 1
    lastRequest = request
    if failures > 0 {
      failures -= 1
      throw ConferencePublicationError.apiFailed
    }
    return ConferencePublication(
      pullRequestURL: "https://github.com/wowlocal/crew18-sim/pull/42",
      branch: "conference/\(request.submissionID.uuidString.lowercased())",
      commit: request.commit,
      actor: "crew18-bot"
    )
  }
}
