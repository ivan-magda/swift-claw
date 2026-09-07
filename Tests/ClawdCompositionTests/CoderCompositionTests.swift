import ClawCoder
import ClawCore
import ClawData
import ClawGateway
import ClawLLM
import ClawTestSupport
import ClawTools
import ClawWorkspace
import Foundation
import GRDB
import Testing

@testable import clawd

@Suite struct CoderCompositionTests {
  @Test func approvedBootReplayUsesComposedCoderWithVMDisabled() async throws {
    // given
    let fixture = try CoderCompositionFixture()
    defer { fixture.cleanup() }
    let coordination = DaemonBuilder.TurnCoordination()
    let coder = await fixture.builder.prepareCoder(coordination: coordination)
    let service = try #require(coder.service)
    let sandbox = await fixture.builder.prepareSandbox()
    let stack = try fixture.builder.makeRosterStack(http: fixture.http)
    let cooldown = PrimaryRouteCooldown(longSeconds: 900, clock: ContinuousClock())
    let workspace = FileSystemWorkspace(root: fixture.root.appendingPathComponent("workspace"))
    let agent = fixture.builder.makeAgentStack(
      roster: stack.roster,
      cooldown: cooldown,
      workspace: workspace,
      costResolver: CostResolver(priceTable: PriceFileLoader.load(), referenceUSDPerToken: 0.00001),
      sandbox: sandbox,
      mcpTools: [],
      coderTools: coder.tools
    )
    // A prepared request was approved before the previous process claimed execution.
    try await service.start()
    let proposal = ToolCall(
      id: "coder-composition-proposal",
      name: CoderToolNames.submit,
      argumentsJSON: """
        {"source":{"githubRepository":{"url":"https://github.com/example/project"}},
        "task":"Fix retry","workspace":"\(CoderWorkspaceMode.separate.rawValue)",
        "deliverable":"\(CoderDeliverable.localChanges.rawValue)"}
        """
    )
    let proposed = await agent.toolDispatcher.dispatch(
      call: proposal,
      context: ToolDispatchContext(
        sessionTainted: false,
        runIngestedUntrusted: false,
        assemblyPrivateData: false,
        runPrivateData: false,
        sessionHasPrivateData: false,
        approvalAlreadyPending: false,
        executionContext: ToolExecutionContext(
          runId: 1,
          sessionId: 1,
          chatId: 7,
          requesterUserId: 7,
          origin: .interactive,
          mode: .direct,
          toolCallId: proposal.id,
          approvalId: nil
        )
      )
    )
    let recorded = try #require(proposed.requiresApproval)
    #expect(recorded.reason == .coderSubmit)
    #expect(await fixture.backend.startedJobIDs.isEmpty)
    let prepared = try JSONDecoder().decode(
      CoderPreparedRequest.self,
      from: Data(recorded.canonicalArgsJSON.utf8)
    )
    let context = try fixture.approvedContext(prepared)
    let policy = agent.contextBuilder.currentPolicyVersion()
    try await fixture.queue.write { db in
      try db.execute(
        sql: "UPDATE runs SET state = ?, policy_version = ? WHERE id = ?",
        arguments: [RunState.awaitingApproval.rawValue, policy, context.runId]
      )
      try db.execute(
        sql: "UPDATE approvals SET policy_version = ? WHERE id = ?",
        arguments: [policy, context.approvalId]
      )
    }
    try await service.shutdown()
    let restarted = await fixture.builder.prepareCoder(coordination: coordination)
    let restartedService = try #require(restarted.service)
    let restartedAgent = fixture.builder.makeAgentStack(
      roster: stack.roster,
      cooldown: cooldown,
      workspace: workspace,
      costResolver: CostResolver(priceTable: PriceFileLoader.load(), referenceUSDPerToken: 0.00001),
      sandbox: sandbox,
      mcpTools: [],
      coderTools: restarted.tools
    )
    let restartedRunner = fixture.builder.makeTurnRunner(
      coordination: coordination,
      agentStack: restartedAgent,
      costPolicy: stack.roster.primary.costPolicy,
      imageCache: ImageCache()
    )
    let restartedFabric = fixture.builder.makeApprovalFabric(
      coordination: coordination,
      agentStack: restartedAgent,
      turnRunner: restartedRunner
    )

    // when
    await fixture.builder.bootSequence(
      coordination: coordination,
      waiter: restartedFabric.waiter,
      heartbeatOwner: nil,
      coder: restartedService
    )()
    let started = await fixture.backend.started.waitUntilOpen()
    fixture.backend.releaseAll()
    _ = await coordination.lanes.drain(timeout: .seconds(5), clock: ContinuousClock())
    try await restartedService.shutdown()

    // then
    #expect(started)
    #expect(!fixture.builder.config.exec.enabled)
    let names = Set(restartedAgent.toolDispatcher.definitions.map(\.name))
    #expect(
      names.isSuperset(of: [CoderToolNames.submit, CoderToolNames.status, CoderToolNames.cancel])
    )
    #expect(!names.contains(ExecuteCodeTool.name))
    let id = try #require(await fixture.backend.startedJobIDs.first)
    let job = try #require(try fixture.builder.stores.coderJobs.job(id: id))
    #expect(job.prepared.executionPolicyID == namesPolicy(restarted.tools))
    #expect(job.origin.approvalID == context.approvalId)
    #expect(!job.slotReserved)
  }

  @Test(arguments: [CodexAuthenticationStatus.missing, .profileUnverified])
  func authenticationFactsControlSubmissionWithoutDisablingRecovery(
    authentication: CodexAuthenticationStatus
  ) async throws {
    // given
    let fixture = try CoderCompositionFixture(authentication: authentication)
    defer { fixture.cleanup() }

    // when
    let coder = await fixture.builder.prepareCoder(coordination: .init())
    let service = try #require(coder.service)
    try await service.start()
    let preparation: Result<CoderPreparedRequest, any Error>
    do {
      let prepared = try await service.prepare(CoderCompositionFixture.request)
      preparation = .success(prepared)
    } catch { preparation = .failure(error) }
    try await service.shutdown()

    // then
    let submits = coder.tools.contains {
      $0.definition.name == CoderToolNames.submit
    }
    #expect(
      coder.checks.contains {
        $0.key == CoderHealthRows.Key.authentication && !$0.ok
      }
    )
    switch authentication {
    case .profileUnverified:
      #expect(submits)
      #expect(try preparation.get().executionPolicyID == namesPolicy(coder.tools))
    default:
      #expect(!submits)
      #expect(throws: CoderError.self) {
        try preparation.get()
      }
    }
  }

  @Test func disabledDoesNotResolveBackend() async throws {
    // given
    let fixture = try CoderCompositionFixture(enabled: false)
    defer { fixture.cleanup() }
    var builder = fixture.builder
    builder.resolveCoder = { _ in
      Issue.record("Disabled Coder resolved its backend")
      throw CoderError.unavailable("not installed")
    }

    // when
    let coder = await builder.prepareCoder(coordination: .init())

    // then
    #expect(coder.service == nil)
    #expect(coder.tools.isEmpty)
  }

  @Test func unavailableBackendStillReconcilesReservedJobs() async throws {
    // given
    let fixture = try CoderCompositionFixture()
    defer { fixture.cleanup() }
    let original = await fixture.builder.prepareCoder(coordination: .init())
    let first = try #require(original.service)
    try await first.start()
    let prepared = try await first.prepare(CoderCompositionFixture.request)
    let context = try fixture.approvedContext(prepared)
    let origin = CoderOrigin(
      runID: context.runId,
      sessionID: context.sessionId,
      requesterUserID: 7,
      chatID: 7,
      toolCallID: context.toolCallId,
      approvalID: try #require(context.approvalId)
    )
    let id = UUID()
    _ = try fixture.builder.stores.coderJobs.admit(
      id: id,
      prepared: prepared,
      origin: origin,
      maxConcurrentJobs: 1,
      now: Date()
    )
    try await first.shutdown()
    var restarted = fixture.builder
    restarted.resolveCoder = { _ in
      throw CoderError.unavailable("not installed")
    }

    // when
    let coder = await restarted.prepareCoder(coordination: .init())
    let service = try #require(coder.service)
    try await service.start()
    try await service.shutdown()

    // then
    let job = try #require(try restarted.stores.coderJobs.job(id: id))
    #expect(job.state == .interrupted)
    #expect(
      coder.checks.contains {
        $0.key == CoderHealthRows.Key.available && !$0.ok
      }
    )
    #expect(!job.slotReserved)
    #expect(
      !coder.tools.contains {
        $0.definition.name == CoderToolNames.submit
      }
    )
    #expect(
      try restarted.stores.outbox.pendingOutbound().contains {
        $0.payload.contains(id.uuidString)
      }
    )
    #expect(await fixture.backend.startedJobIDs.isEmpty)
  }

  @Test func offlineRowsDoNotProbe() async throws {
    // given
    let fixture = try CoderCompositionFixture()
    defer { fixture.cleanup() }

    // when
    var doctor = DoctorCommand()
    doctor.checkConfig = true
    let rows = await doctor.coderRows(
      config: fixture.builder.config.coder,
      resolve: { _ in
        Issue.record("Offline doctor launched a Coder probe")
        throw CoderError.unavailable("unexpected probe")
      }
    )

    // then
    #expect(
      rows.contains {
        $0.key == CoderHealthRows.Key.available && $0.value.contains("unverified")
      }
    )
  }

  @Test func persistedHealthSurvivesReleaseAndFailsUnreadable() async throws {
    // given
    let fixture = try CoderCompositionFixture()
    defer { fixture.cleanup() }
    let coder = await fixture.builder.prepareCoder(coordination: .init())
    let service = try #require(coder.service)
    try await service.start()
    let prepared = try await service.prepare(CoderCompositionFixture.request)
    let context = try fixture.approvedContext(prepared)
    let origin = CoderOrigin(
      runID: context.runId,
      sessionID: context.sessionId,
      requesterUserID: 7,
      chatID: 7,
      toolCallID: context.toolCallId,
      approvalID: try #require(context.approvalId)
    )
    let store = fixture.builder.stores.coderJobs
    let id = UUID()
    _ = try store.admit(
      id: id,
      prepared: prepared,
      origin: origin,
      maxConcurrentJobs: 1,
      now: Date()
    )
    let failed = CoderResult(
      state: .failed,
      summary: "Failed",
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
      failure: CoderFailure(stage: .permission, message: "blocked task7-sensitive-token")
    )
    _ = try store.complete(
      id: id,
      expectedState: .admitted,
      result: failed,
      chunks: [],
      releaseReservation: true,
      now: Date()
    )
    try await service.shutdown()
    let redactor = SecretRedactor(secretValues: ["task7-sensitive-token"])

    // when
    let rows = CoderHealthRows.persisted(store: store, redactor: redactor)
    try await fixture.queue.write { db in
      try db.execute(sql: "DROP TABLE coder_jobs")
    }
    let unreadable = CoderHealthRows.persisted(store: store, redactor: redactor)

    // then
    let last = try #require(
      rows.first {
        $0.key == CoderHealthRows.Key.lastFailure
      }
    )
    #expect(last.value.contains(id.uuidString))
    #expect(last.value.contains(CoderJobState.failed.rawValue))
    #expect(!last.value.contains("task7-sensitive-token"))
    #expect(
      rows.first {
        $0.key == CoderHealthRows.Key.reserved
      }?.value.hasPrefix("0") == true
    )
    for key in [
      CoderHealthRows.Key.reserved, CoderHealthRows.Key.ownership, CoderHealthRows.Key.lastFailure,
    ] {
      let row = try #require(
        unreadable.first {
          $0.key == key
        }
      )
      #expect(!row.ok)
      #expect(row.value.contains("unreadable"))
    }
  }

  private func namesPolicy(_ tools: [any Tool]) -> String? {
    tools.first {
      $0.definition.name == CoderToolNames.submit
    }?.definition.invocationIdentity
  }
}
