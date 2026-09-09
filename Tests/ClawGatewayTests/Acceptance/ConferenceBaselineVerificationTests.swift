import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import Logging
import Testing

@testable import ClawGateway

@Suite struct ConferenceBaselineVerificationTests {
  @Test func mismatchedObservedBaselineNeverReachesPublisher() async throws {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let submissions = ConferenceStoreGRDB(writer: queue)
    let coderJobs = CoderJobStoreGRDB(writer: queue)
    let outbox = OutboxStoreGRDB(writer: queue)
    let sourcePath = "/conference/source/day-1"
    let expectedBaseline = String(repeating: "b", count: 40)
    let observedBaseline = String(repeating: "a", count: 40)
    let finalCommit = String(repeating: "c", count: 40)
    let item = ConferenceCase(
      id: "day-1",
      title: "Accessibility regression",
      prompt: "Propose a solution.",
      repositoryURL: "https://github.com/wowlocal/crew18-sim",
      baselineRef: expectedBaseline,
      baseBranch: "challenge/day-1"
    )
    let origin = ConferenceApprovedOrigin(
      runID: 1,
      sessionID: 1,
      chatID: 101,
      requesterUserID: 101,
      mode: .direct,
      toolCallID: "challenge-submit",
      approvalID: 1
    )
    let inserted = try submissions.insertSubmission(
      id: UUID(),
      prepared: PreparedConferenceSubmission(caseSnapshot: item, answer: "Use an actor."),
      origin: origin,
      now: Date()
    )
    guard case .inserted(let submission) = inserted else {
      Issue.record("Expected fresh submission")
      return
    }
    _ = try submissions.claimNextQueued(now: Date())

    let request = CoderRequest(
      source: .local(path: sourcePath),
      task: "test",
      workspace: .separate,
      startRef: expectedBaseline,
      deliverable: .localChanges,
      baseBranch: nil,
      instructions: nil,
      publishExistingChanges: false
    )
    let prepared = CoderPreparedRequest(
      request: request,
      canonicalSource: sourcePath,
      checkoutPath: sourcePath,
      commonGitDirectory: "\(sourcePath)/.git",
      executionPolicyID: "conference-test-policy",
      publicationRepository: nil
    )
    let admission = try coderJobs.admit(
      id: UUID(),
      prepared: prepared,
      origin: CoderOrigin(
        runID: origin.runID,
        sessionID: origin.sessionID,
        requesterUserID: origin.requesterUserID,
        chatID: origin.chatID,
        toolCallID: origin.toolCallID,
        approvalID: origin.approvalID
      ),
      maxConcurrentJobs: 1,
      now: Date()
    )
    guard case .admitted(let job) = admission else {
      Issue.record("Expected Coder admission")
      return
    }
    _ = try coderJobs.complete(
      id: job.id,
      expectedState: .admitted,
      result: CoderResult(
        state: .succeeded,
        summary: "Committed locally",
        workspacePath: "/conference/workspace",
        startingCommit: observedBaseline,
        baselineObserved: true,
        changedFiles: ["Sources/Feature.swift"],
        branch: nil,
        commit: finalCommit,
        publication: .absent,
        reportedChecks: ["tests passed"],
        reportedUsage: nil,
        commitAuthor: "Conference Coder",
        githubActor: nil,
        failure: nil
      ),
      chunks: [],
      releaseReservation: true,
      now: Date()
    )
    _ = try submissions.attachCoderJob(
      submissionID: submission.id,
      coderJobID: job.id,
      now: Date()
    )

    let publisher = RejectUnexpectedPublication()
    let service = ConferenceWorkflowService(
      config: ConferenceConfig(
        enabled: true,
        activeCase: item,
        expectedGitHubActor: "crew18-bot"
      ),
      sourcePath: sourcePath,
      store: submissions,
      coder: BaselineUnusedCoder(),
      coderJobs: coderJobs,
      publisher: publisher,
      outbox: outbox,
      notifyOutbox: {},
      logger: Logger(label: "conference-baseline-verification")
    )

    let runner = Task { try await service.run() }
    defer { runner.cancel() }

    let finished = try await pollUntilTrue {
      try submissions.submission(id: submission.id)?.state == .needsReview
    }
    #expect(finished)
    #expect(await publisher.attempts == 0)
    let terminal = try #require(try submissions.submission(id: submission.id))
    #expect(terminal.pullRequestURL == nil)
    #expect(terminal.failureReason?.contains("approved baseline") == true)

    runner.cancel()
    _ = await runner.result
  }
}

private actor RejectUnexpectedPublication: ConferencePublishing {
  private(set) var attempts = 0

  func publish(_ request: ConferencePublicationRequest) async throws -> ConferencePublication {
    attempts += 1
    throw ConferencePublicationError.invalidCommit
  }
}

private struct BaselineUnusedCoder: CoderServing {
  func prepare(_ request: CoderRequest) async throws -> CoderPreparedRequest {
    throw CoderError.unavailable("unused")
  }

  func submit(
    _ prepared: CoderPreparedRequest,
    context: ToolExecutionContext
  ) async throws -> CoderJob {
    throw CoderError.unavailable("unused")
  }

  func status(id: UUID, context: ToolExecutionContext) async throws -> CoderJob {
    throw CoderError.unavailable("unused")
  }

  func cancel(id: UUID, context: ToolExecutionContext) async throws -> CoderJob {
    throw CoderError.unavailable("unused")
  }
}
