import ClawAgent
import ClawCore
import ClawData
import ClawTestSupport
import ClawTools
import Foundation
import Testing

@testable import ClawGateway

@Suite struct CoderApprovalFlowTests {
  @Test(arguments: [ChatMode.direct, .group])
  func approvalRestoresRecordedRequestAndAuthenticatedOrigin(mode: ChatMode) async throws {
    // given
    let requester: Int64 = mode == .group ? 41 : 7
    let participant: Int64 = mode == .group ? 42 : requester
    let chat: Int64 = mode == .group ? -100_123 : requester
    let thread: Int64? = mode == .group ? 77 : nil
    let membership = GroupMembershipStub(chatId: chat, memberUserIds: [participant])
    let groups: Set<Int64> = mode == .group ? [chat] : []
    let identity = BotIdentity(id: 900, username: "claw_bot")
    let backend = ScriptedCoderBackend(invocations: [.init(result: CoderServiceFixture.result())])
    let first = try makeSC3Harness(
      scripts: [[toolCallResponse([proposal])]],
      httpResponses: [:],
      coderBackend: backend,
      groupChats: groups,
      groupMembership: membership,
      botIdentity: identity
    )
    let storage = CoderToolStorageCleanup()
    try await first.withJoinedCleanup(backend: backend, storage: storage) {
      let firstService = try #require(first.coderService)
      try await firstService.start()
      _ = await first.router.handle(
        rawUpdate: textUpdate(
          id: 1,
          from: requester,
          chat: chat,
          text: "@claw_bot Fix retry handling",
          chatKind: mode == .group ? .supergroup : .private,
          messageThreadId: thread
        )
      )
      let approval = try #require(
        try await pollUntil {
          try fetchApprovals(databasePath: first.databasePath).first
        }
      )
      #expect(approval.reason == ApprovalReason.coderSubmit.rawValue)
      #expect(approval.state == ApprovalState.pending.rawValue)
      #expect(try first.stores.coderJobs.reservedJobs().isEmpty)
      #expect(await backend.startedJobIDs.isEmpty)
      let prompt = try #require(
        try first.stores.outbox.pendingOutbound().first { $0.approvalId == approval.id }
      )
      #expect(prompt.target.messageThreadId == thread)
      try first.stores.outbox.markSent(
        deliveryKey: prompt.deliveryKey,
        telegramMessageId: 900,
        now: Date()
      )
      try await first.stop()
      let restarted = try makeSC3Harness(
        scripts: [[okResponse(content: "Started")]],
        httpResponses: [:],
        databasePath: first.databasePath,
        workspaceRoot: first.workspaceRoot,
        coderBackend: backend,
        groupChats: groups,
        groupMembership: membership,
        botIdentity: identity
      )
      try await restarted.withJoinedCleanup(
        backend: backend,
        storage: storage,
        removeFilesOnExit: false
      ) {
        let service = try #require(restarted.coderService)
        try await service.start()
        await restarted.runBootReconciliation()

        // when
        _ = await restarted.router.handle(
          rawUpdate: callbackUpdate(
            id: 2,
            from: participant,
            chat: chat,
            messageId: 900,
            data: approveData(approval.nonce)
          )
        )
        let started = await backend.started.waitUntilOpen()

        // then
        #expect(started)
        let id = try #require(await backend.startedJobIDs.first)
        let job = try #require(try restarted.stores.coderJobs.job(id: id))
        #expect(job.prepared == CoderServiceFixture.request())
        #expect(job.origin.runID == approval.runId)
        let persistedApproval = try #require(
          try restarted.stores.approvals.approval(id: approval.id)
        )
        #expect(job.origin.sessionID == persistedApproval.sessionId)
        #expect(job.origin.requesterUserID == requester)
        #expect(job.origin.chatID == chat)
        #expect(job.origin.approvalID == approval.id)
        #expect(job.origin.toolCallID == proposal.id)
        #expect(await backend.startedJobIDs == [job.id])
        backend.allowCompletion.open()
        let report = try #require(
          try await pollUntil {
            try restarted.stores.outbox.pendingOutbound().first { row in
              row.payload.contains(job.id.uuidString)
                && row.payload.contains(CoderJobState.succeeded.rawValue)
            }
          }
        )
        let expectedTarget =
          mode == .group
          ? DeliveryTarget(chatId: chat, messageThreadId: thread, replyToMessageId: 1)
          : .chat(chat)
        #expect(report.target == expectedTarget)
      }
    }
  }

  @Test func ownerCanInspectAndCancelThroughDispatcher() async throws {
    // given
    let fixture = try CoderServiceFixture()
    try await fixture.withJoinedCleanup {
      try await fixture.service.start()
      let job = try await fixture.submitFirst()
      #expect(await fixture.backend.started.waitUntilOpen())
      let dispatcher = dispatcher(service: fixture.service)
      let context = dispatchContext(fixture.ownerContext)

      // when
      let status = await dispatcher.dispatch(
        call: jobCall(CoderToolNames.status, id: job.id),
        context: context
      )
      let cancelled = await dispatcher.dispatch(
        call: jobCall(CoderToolNames.cancel, id: job.id),
        context: context
      )

      // then
      #expect(status.observation.status == .ok)
      #expect(status.observation.content.contains(job.id.uuidString))
      #expect(status.observation.content.contains(CoderJobState.running.rawValue))
      #expect(cancelled.observation.status == .ok)
      let state = try fixture.store.job(id: job.id)?.state
      #expect(state == .stopping || state == .cancelled)
    }
  }

  @Test func proactiveProposalCannotParkCoder() async throws {
    // given
    let backend = ScriptedCoderBackend(invocations: [.init(result: CoderServiceFixture.result())])
    let harness = try makeSC3Harness(
      scripts: [
        [toolCallResponse([proposal]), okResponse(content: "Cannot delegate proactively")]
      ],
      httpResponses: [:],
      coderBackend: backend
    )
    try await harness.withJoinedCleanup(backend: backend) {
      try await harness.coderService?.start()
      let now = Date()
      let scheduled = try harness.stores.scheduledJobs.create(
        NewScheduledJob(
          ownerChatId: 7,
          label: "retry",
          prompt: "Fix retry handling",
          recurrence: nil,
          timezone: "UTC",
          nextOccurrence: now
        ),
        now: now
      )
      guard
        case .fired(let fire) = try harness.stores.scheduledJobs.fireNow(
          jobId: scheduled.id,
          now: now
        )
      else {
        Issue.record("Scheduled run was not created")
        return
      }
      let origin = try #require(try harness.stores.runs.pickUp(runId: fire.runId, now: now))

      // when
      let outcome = try await harness.agent.runTurn(
        runId: fire.runId,
        sessionId: fire.sessionId,
        chatId: fire.ownerChatId,
        buildResult: BuildResult(messages: [], ownerNotices: [], hasPrivateDataAccess: false),
        sessionTainted: false,
        hasPinnedLessons: false,
        sessionHasPrivateData: false,
        todayTokens: 0,
        todayUSD: 0,
        origin: origin
      )

      // then
      if case .suspended = outcome.result {
        Issue.record("Proactive Coder proposal parked approval")
      }
      #expect(outcome.exchanges.first?.observations.first?.status == .error)
      #expect(await backend.startedJobIDs.isEmpty)
    }
  }

  @Test func changedExecutionPolicyVoidsParkedApproval() async throws {
    // given
    let backend = ScriptedCoderBackend(invocations: [.init(result: CoderServiceFixture.result())])
    let first = try makeSC3Harness(
      scripts: [[toolCallResponse([proposal])]],
      httpResponses: [:],
      coderBackend: backend
    )
    let storage = CoderToolStorageCleanup()
    try await first.withJoinedCleanup(backend: backend, storage: storage) {
      try await first.coderService?.start()
      _ = await first.router.handle(
        rawUpdate: textUpdate(id: 1, from: 7, text: "Fix retry handling")
      )
      let approval = try #require(
        try await pollUntil {
          try fetchApprovals(databasePath: first.databasePath).first
        }
      )
      let changed = try makeSC3Harness(
        scripts: [],
        httpResponses: [:],
        databasePath: first.databasePath,
        workspaceRoot: first.workspaceRoot,
        coderBackend: backend,
        coderPolicyID: "changed-policy"
      )
      try await changed.withJoinedCleanup(
        backend: backend,
        storage: storage,
        removeFilesOnExit: false
      ) {
        // when
        _ = await changed.router.handle(
          rawUpdate: callbackUpdate(id: 2, from: 7, data: approveData(approval.nonce))
        )

        // then
        #expect(
          try fetchApprovals(databasePath: first.databasePath).first?.state
            == ApprovalState.rejected.rawValue
        )
        #expect(
          try changed.auditRows().contains { row in
            row.decision == ApprovalDecision.stalePolicy.rawValue
          }
        )
        #expect(await backend.startedJobIDs.isEmpty)
        try await first.stop()
      }
    }
  }
}

// MARK: - Fixtures

private extension CoderApprovalFlowTests {
  var proposal: ToolCall {
    ToolCall(
      id: "coder-1",
      name: CoderToolNames.submit,
      argumentsJSON: """
        {"source":{"local":{"path":"/fixture/repository-1"}},"task":"Fix retry handling",
        "workspace":"inPlace","deliverable":"localChanges","publish_existing_changes":false}
        """
    )
  }

  func dispatcher(service: any CoderServing) -> GatedToolDispatcher {
    let redactor = SecretRedactor(secretValues: [])
    return GatedToolDispatcher(
      registry: ToolRegistry(tools: [
        CoderStatusTool(service: service, redactor: redactor),
        CoderCancelTool(service: service, redactor: redactor),
      ]),
      gate: ToolPolicyGate(
        argGuard: ExfilArgGuard(secretValues: []),
        privateFileLoader: { [] },
        enabledDangerousTools: []
      )
    )
  }

  func dispatchContext(_ context: ToolExecutionContext) -> ToolDispatchContext {
    ToolDispatchContext(
      sessionTainted: false,
      runIngestedUntrusted: false,
      assemblyPrivateData: false,
      runPrivateData: false,
      sessionHasPrivateData: false,
      approvalAlreadyPending: false,
      executionContext: context
    )
  }

  func jobCall(_ name: String, id: UUID) -> ToolCall {
    ToolCall(id: name, name: name, argumentsJSON: "{\"job_id\":\"\(id.uuidString)\"}")
  }
}
