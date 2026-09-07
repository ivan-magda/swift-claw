import ClawCore
import ClawGateway
import ClawLLM
import ClawTestSupport
import Foundation
import Testing

@testable import ClawCoder
@testable import clawd

extension CoderCompositionTests {
  @Test func disabledStillReconcilesAndReportsReservedJobs() async throws {
    // given
    let fixture = try CoderCompositionFixture(limit: 2)
    defer { fixture.cleanup() }
    let original = await fixture.builder.prepareCoder(coordination: .init())
    let originalService = try #require(original.service)
    try await originalService.start()
    let prepared = try await originalService.prepare(CoderCompositionFixture.request)
    try await originalService.shutdown()
    let released = try oldJob(fixture, prepared: prepared, updateID: 1)
    let unresolved = try oldJob(fixture, prepared: prepared, updateID: 2)
    let store = fixture.builder.stores.coderJobs
    try #require(try store.markRunning(id: unresolved.id, now: Date()))
    let pendingReceipt = CoderProcessReceipt(
      launchID: UUID(),
      phase: .codex,
      hostBootID: try CoderProcessIdentity.bootID(),
      pid: nil,
      pgid: nil,
      birthIdentity: nil
    )
    try store.recordProcess(
      id: unresolved.id,
      event: .willLaunch(pendingReceipt),
      now: Date()
    )
    let disabled = try AppConfig.load(environment: [
      AppConfig.EnvKey.stateRoot: fixture.root.path,
      AppConfig.EnvKey.llmModel: CompositionAcceptance.qualifiedModel,
      AppConfig.EnvKey.coderEnabled: "false",
    ])
    var restarted = try CompositionAcceptance.makeBuilder(http: fixture.http, config: disabled)
    restarted.resolveCoder = { _ in
      Issue.record("Disabled recovery resolved the native backend")
      throw CoderError.unavailable("not installed")
    }
    let context = ToolExecutionContext(
      runId: released.origin.runID,
      sessionId: released.origin.sessionID,
      chatId: released.origin.chatID,
      requesterUserId: released.origin.requesterUserID,
      origin: .interactive,
      mode: .direct,
      toolCallId: released.origin.toolCallID,
      approvalId: released.origin.approvalID
    )

    for _ in 0..<2 {
      // when
      let coder = await restarted.prepareCoder(coordination: .init())
      let service = try #require(coder.service)
      do { try await service.start() } catch {
        try? await service.shutdown()
        throw error
      }
      await #expect(throws: CoderError.self) {
        try await service.prepare(CoderCompositionFixture.request)
      }
      await #expect(throws: CoderError.self) {
        try await service.submit(prepared, context: context)
      }
      let reporter = restarted.makeDoctorReporter(
        sandbox: await restarted.prepareSandbox(),
        cooldown: PrimaryRouteCooldown(longSeconds: 900, clock: ContinuousClock()),
        mcpOutcomes: [],
        coder: coder
      )
      let report = await reporter.report()
      try await service.shutdown()

      // then
      #expect(coder.tools.isEmpty)
      let releasedJob = try #require(try store.job(id: released.id))
      let unresolvedJob = try #require(try store.job(id: unresolved.id))
      #expect(releasedJob.state == .interrupted)
      #expect(!releasedJob.slotReserved)
      #expect(unresolvedJob.state == .interrupted)
      #expect(unresolvedJob.slotReserved)
      #expect(unresolvedJob.ownership == .unresolved)
      #expect(unresolvedJob.processReceipt == pendingReceipt)
      let notices = try restarted.stores.outbox.pendingOutbound().filter {
        $0.approvalId == nil
      }
      for id in [released.id, unresolved.id] {
        let matching = notices.filter {
          $0.payload.contains(id.uuidString)
        }
        #expect(matching.count == 1)
      }
      #expect(
        report.checks.contains {
          $0.key == CoderHealthRows.Key.enabled && $0.value == "false"
        }
      )
      #expect(
        report.checks.contains {
          $0.key == CoderHealthRows.Key.reserved && $0.value.hasPrefix("1")
        }
      )
      #expect(
        report.checks.contains {
          $0.key == CoderHealthRows.Key.ownership
            && $0.value.contains(unresolved.id.uuidString) && !$0.ok
        }
      )
      #expect(
        report.checks.contains {
          $0.key == CoderHealthRows.Key.lastFailure
            && $0.value.contains(CoderJobState.interrupted.rawValue)
        }
      )
      #expect(await fixture.backend.startedJobIDs.isEmpty)
    }
  }
}

// MARK: - Persisted Enabled Jobs

private extension CoderCompositionTests {
  func oldJob(
    _ fixture: CoderCompositionFixture,
    prepared: CoderPreparedRequest,
    updateID: Int64
  ) throws -> CoderJob {
    let origin = try CoderApprovedOriginFixture.make(
      queue: fixture.queue,
      updateID: updateID,
      prepared: prepared,
      now: Date()
    )
    let id = UUID()
    _ = try fixture.builder.stores.coderJobs.admit(
      id: id,
      prepared: prepared,
      origin: origin,
      maxConcurrentJobs: fixture.builder.config.coder.maxConcurrentJobs,
      now: Date()
    )
    return try #require(try fixture.builder.stores.coderJobs.job(id: id))
  }
}
