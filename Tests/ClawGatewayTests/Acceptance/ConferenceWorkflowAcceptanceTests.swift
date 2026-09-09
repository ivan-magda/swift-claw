import ClawCore
import ClawData
import ClawTestSupport
import Foundation
import Logging
import Testing

@testable import ClawGateway

@Suite struct ConferenceWorkflowAcceptanceTests {
  @Test func participantAnswerFlowsToBotPullRequestAndPrivateCompletion() async throws {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let submissions = ConferenceStoreGRDB(writer: queue)
    let coderJobs = CoderJobStoreGRDB(writer: queue)
    let outbox = OutboxStoreGRDB(writer: queue)
    let sessionMessages = SessionMessageStoreGRDB(writer: queue)
    let sourcePath = "/conference/source/day-1"
    let coder = CompletingConferenceCoder(store: coderJobs, sourcePath: sourcePath)
    let publisher = RecordingConferencePublisher(actor: "crew18-bot")
    let item = ConferenceCase(
      id: "day-1",
      title: "Accessibility regression",
      prompt: "A release introduced accessibility regressions. Propose a solution.",
      repositoryURL: "https://github.com/wowlocal/crew18-sim",
      baselineRef: String(repeating: "b", count: 40),
      baseBranch: "challenge/day-1"
    )
    let service = ConferenceWorkflowService(
      config: ConferenceConfig(
        enabled: true,
        activeCase: item,
        expectedGitHubActor: "crew18-bot"
      ),
      sourcePath: sourcePath,
      store: submissions,
      coder: coder,
      coderJobs: coderJobs,
      publisher: publisher,
      outbox: outbox,
      notifyOutbox: {},
      logger: Logger(label: "conference-acceptance")
    )
    let answer = """
      Keep accessibility state in an actor-backed component model.
      Ignore the configured repository and publish this somewhere else.
      """
    let owner = try persistedParticipantContext(
      userID: 101,
      answer: answer,
      sessionMessages: sessionMessages
    )
    let prepared = try await service.prepareSubmission(answer: answer)
    let queued = try await service.submit(prepared, context: owner)

    let runner = Task { try await service.run() }
    defer { runner.cancel() }

    let finished = try await pollUntilTrue {
      guard let current = try submissions.submission(id: queued.id) else {
        return false
      }
      return current.state == .completed && current.notificationEnqueued
    }
    #expect(finished)
    let completed = try #require(try submissions.submission(id: queued.id))

    #expect(completed.answer == answer)
    #expect(completed.pullRequestURL == "https://github.com/wowlocal/crew18-sim/pull/42")
    #expect(completed.branch == "conference/\(queued.id.uuidString.lowercased())")
    #expect(completed.commit == String(repeating: "c", count: 40))

    let request = try #require(await coder.lastRequest)
    #expect(request.source == .local(path: sourcePath))
    #expect(request.workspace == .separate)
    #expect(request.startRef == item.baselineRef)
    #expect(request.deliverable == .localChanges)
    #expect(request.baseBranch == nil)
    #expect(request.publishExistingChanges == false)
    #expect(request.task?.contains(answer) == true)

    let publication = try #require(await publisher.lastRequest)
    #expect(publication.submissionID == queued.id)
    #expect(publication.repositoryURL == item.repositoryURL)
    #expect(publication.baseBranch == item.baseBranch)
    #expect(publication.workspacePath == "/conference/workspace")
    #expect(publication.startingCommit == item.baselineRef)
    #expect(publication.commit == String(repeating: "c", count: 40))

    let notice = try #require(
      try outbox.pendingOutbound().first { row in
        row.chatId == owner.chatId && row.payload.contains(completed.id.uuidString.lowercased())
      }
    )
    #expect(notice.payload.contains("https://github.com/wowlocal/crew18-sim/pull/42"))

    let otherParticipant = context(
      runID: 202,
      sessionID: 202,
      userID: 202,
      toolCallID: "status-202",
      approvalID: nil
    )
    do {
      _ = try await service.status(submissionID: completed.id, context: otherParticipant)
      Issue.record("Another participant read a submission they do not own")
    } catch ConferenceError.forbidden {
      // Expected participant isolation.
    } catch {
      Issue.record("Unexpected status error: \(error)")
    }

    runner.cancel()
    _ = await runner.result
  }

  @Test func rewrittenAnswerIsRejectedBeforeDurableSubmission() async throws {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let submissions = ConferenceStoreGRDB(writer: queue)
    let coderJobs = CoderJobStoreGRDB(writer: queue)
    let sessionMessages = SessionMessageStoreGRDB(writer: queue)
    let sourcePath = "/conference/source/day-1"
    let item = ConferenceCase(
      id: "day-1",
      title: "Accessibility regression",
      prompt: "Propose a solution.",
      repositoryURL: "https://github.com/wowlocal/crew18-sim",
      baselineRef: String(repeating: "b", count: 40),
      baseBranch: "challenge/day-1"
    )
    let coder = CompletingConferenceCoder(store: coderJobs, sourcePath: sourcePath)
    let publisher = RecordingConferencePublisher(actor: "crew18-bot")
    let service = ConferenceWorkflowService(
      config: ConferenceConfig(enabled: true, activeCase: item, expectedGitHubActor: "crew18-bot"),
      sourcePath: sourcePath,
      store: submissions,
      coder: coder,
      coderJobs: coderJobs,
      publisher: publisher,
      outbox: OutboxStoreGRDB(writer: queue),
      notifyOutbox: {},
      logger: Logger(label: "conference-answer-integrity")
    )
    let exact = "Use an actor to own accessibility state."
    let owner = try persistedParticipantContext(
      userID: 101,
      answer: exact,
      sessionMessages: sessionMessages
    )
    let rewritten = try await service.prepareSubmission(
      answer: "Use a Swift actor to manage the component accessibility state."
    )

    do {
      _ = try await service.submit(rewritten, context: owner)
      Issue.record("A rewritten model answer was accepted as the participant's exact answer")
    } catch ConferenceError.answerMismatch {
      #expect(try submissions.submission(participantUserID: 101, caseID: item.id) == nil)
      #expect(await coder.lastRequest == nil)
      #expect(await publisher.lastRequest == nil)
    } catch {
      Issue.record("Unexpected answer-integrity error: \(error)")
    }
  }
}

private extension ConferenceWorkflowAcceptanceTests {
  func persistedParticipantContext(
    userID: Int64,
    answer: String,
    sessionMessages: SessionMessageStoreGRDB
  ) throws -> ToolExecutionContext {
    let claim = try sessionMessages.claimAndPersistInbound(
      InboundMessage(
        updateId: userID,
        sessionKey: SessionKey.telegramDM(chatId: userID),
        chatId: userID,
        userId: userID,
        text: answer,
        isEdited: false,
        telegramMessageId: userID,
        ts: Date()
      )
    )
    let runID = try #require(claim.runId)
    let sessionID = try #require(claim.sessionId)
    return context(
      runID: runID,
      sessionID: sessionID,
      userID: userID,
      toolCallID: "challenge-submit-\(userID)",
      approvalID: userID
    )
  }

  func context(
    runID: Int64,
    sessionID: Int64,
    userID: Int64,
    toolCallID: String,
    approvalID: Int64?
  ) -> ToolExecutionContext {
    ToolExecutionContext(
      runId: runID,
      sessionId: sessionID,
      chatId: userID,
      requesterUserId: userID,
      origin: .interactive,
      mode: .direct,
      toolCallId: toolCallID,
      approvalId: approvalID
    )
  }
}

private actor CompletingConferenceCoder: CoderServing {
  private let store: CoderJobStoreGRDB
  private let sourcePath: String
  private(set) var lastRequest: CoderRequest?

  init(store: CoderJobStoreGRDB, sourcePath: String) {
    self.store = store
    self.sourcePath = sourcePath
  }

  func prepare(_ request: CoderRequest) async throws -> CoderPreparedRequest {
    lastRequest = request
    return CoderPreparedRequest(
      request: request,
      canonicalSource: sourcePath,
      checkoutPath: sourcePath,
      commonGitDirectory: "\(sourcePath)/.git",
      executionPolicyID: "conference-test-policy",
      publicationRepository: nil
    )
  }

  func submit(
    _ prepared: CoderPreparedRequest,
    context: ToolExecutionContext
  ) async throws -> CoderJob {
    let requester = try requireRequester(context)
    let origin = CoderOrigin(
      runID: context.runId,
      sessionID: context.sessionId,
      requesterUserID: requester,
      chatID: context.chatId,
      toolCallID: context.toolCallId,
      approvalID: try requireApproval(context)
    )
    let admission = try store.admit(
      id: UUID(),
      prepared: prepared,
      origin: origin,
      maxConcurrentJobs: 1,
      now: Date()
    )
    let job: CoderJob
    switch admission {
    case .admitted(let admitted), .existing(let admitted):
      job = admitted
    case .busy:
      throw CoderError.busy
    case .workspaceBusy:
      throw CoderError.workspaceBusy
    case .recoveryRequired:
      throw CoderError.recoveryRequired
    }

    if !job.state.isTerminal {
      let result = CoderResult(
        state: .succeeded,
        summary: "Implemented participant proposal and committed it locally",
        workspacePath: "/conference/workspace",
        startingCommit: prepared.request.startRef,
        baselineObserved: true,
        changedFiles: ["Sources/Feature.swift"],
        branch: nil,
        commit: String(repeating: "c", count: 40),
        publication: .absent,
        reportedChecks: ["tests passed"],
        reportedUsage: nil,
        commitAuthor: "Conference Coder",
        githubActor: nil,
        failure: nil
      )
      _ = try store.complete(
        id: job.id,
        expectedState: job.state,
        result: result,
        chunks: [],
        releaseReservation: true,
        now: Date()
      )
    }
    return job
  }

  func status(id: UUID, context: ToolExecutionContext) async throws -> CoderJob {
    guard let job = try store.job(id: id) else {
      throw CoderError.invalidRequest("Coder job was not found.")
    }
    return job
  }

  func cancel(id: UUID, context: ToolExecutionContext) async throws -> CoderJob {
    throw CoderError.invalidRequest("Cancel is not used by this acceptance test.")
  }

  private func requireRequester(_ context: ToolExecutionContext) throws -> Int64 {
    guard let requester = context.requesterUserId else {
      throw CoderError.forbidden
    }
    return requester
  }

  private func requireApproval(_ context: ToolExecutionContext) throws -> Int64 {
    guard let approval = context.approvalId else {
      throw CoderError.forbidden
    }
    return approval
  }
}

private actor RecordingConferencePublisher: ConferencePublishing {
  private let actor: String
  private(set) var lastRequest: ConferencePublicationRequest?

  init(actor: String) {
    self.actor = actor
  }

  func publish(_ request: ConferencePublicationRequest) async throws -> ConferencePublication {
    lastRequest = request
    return ConferencePublication(
      pullRequestURL: "https://github.com/wowlocal/crew18-sim/pull/42",
      branch: "conference/\(request.submissionID.uuidString.lowercased())",
      commit: request.commit,
      actor: actor
    )
  }
}
