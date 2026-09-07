import ClawData
import ClawLLM
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawCore
@testable import ClawGateway
@testable import clawd

@Suite struct LearningStartupTests {
  @Test func recoveryDoesNotHoldPrimaryDeliveryOrOwnerControl() async throws {
    // given
    let entered = AsyncGate()
    let release = AsyncGate()
    let delivered = AsyncGate()
    let commandHandled = AsyncGate()
    defer { release.open() }
    let updates = LearningAcceptanceUpdates()
    let telegramStep: ScriptedHTTPExecutor.Step = .responding { request in
      if request.url.hasSuffix("/getUpdates") {
        let body = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any]
        if (body?["offset"] as? Int ?? 0) > 1 { commandHandled.open() }
        return try await updates.next()
      }
      if request.url.hasSuffix("/sendMessage") {
        let body = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any]
        if body?["text"] as? String == LearningAcceptanceHarness.answer {
          delivered.open()
        }
        return HTTPResult(
          statusCode: 200,
          headers: [:],
          body: Data(#"{"ok":true,"result":{"message_id":900,"chat":{"id":777}}}"#.utf8)
        )
      }
      return HTTPResult(
        statusCode: 200,
        headers: [:],
        body: Data(#"{"ok":true,"result":true}"#.utf8)
      )
    }
    let telegram = ScriptedHTTPExecutor(Array(repeating: telegramStep, count: 128))
    let reply = try LearningAcceptanceHarness.completion(LearningAcceptanceHarness.noIssue)
    let llm = ScriptedHTTPExecutor([
      .responding { _ in
        entered.open()
        await release.wait()
        guard case .ok(let result) = reply else {
          throw ScriptedTransportFailure(message: "expected buffered completion")
        }
        return result
      }
    ])
    var environment = CompositionAcceptanceHarness.validEnv()
    environment[AppConfig.EnvKey.learningEnabled] = "true"
    environment[AppConfig.EnvKey.llmStreaming] = "false"
    let config = try AppConfig.load(environment: environment)
    defer { try? FileManager.default.removeItem(at: config.stateRoot) }
    var builder = try CompositionAcceptance.makeBuilder(
      http: telegram,
      config: config,
      secrets: Secrets(telegramBotToken: "tg-token", llmApiKey: "sk-test")
    )
    builder.now = {
      LearningAcceptanceHarness.now
    }
    try builder.stores.allowlist.seedAllowlist(userIds: [LearningAcceptanceHarness.owner])
    let backlog = try Self.commitBacklog(
      stores: builder.stores,
      route: config.llm.route.configuredReference
    )
    let bundle = try await builder.build(
      rosterStack: builder.makeRosterStack(http: llm),
      cooldown: PrimaryRouteCooldown(
        longSeconds: config.llm.primaryCooldownSeconds,
        clock: ContinuousClock()
      )
    )
    let daemon = Task {
      try await bundle.daemon.run()
    }
    do {
      // when
      await entered.wait()
      await delivered.wait()
      let command: [String: Any] = [
        "update_id": 1,
        "message": [
          "message_id": 1000, "from": ["id": LearningAcceptanceHarness.owner],
          "chat": ["id": LearningAcceptanceHarness.owner, "type": "private"],
          "text": "/pause \(backlog.jobId)",
        ],
      ]
      let bytes = try JSONSerialization.data(withJSONObject: ["ok": true, "result": [command]])
      await updates.submit(bytes)
      await commandHandled.wait()

      // then
      #expect(try builder.stores.scheduledJobs.job(id: backlog.jobId)?.status == .paused)
      #expect(release.isOpen == false)
      #expect(try builder.stores.learning.evaluation(runId: backlog.runId) == nil)
      release.open()
      let learning = try #require(
        bundle.daemon.services.compactMap {
          $0 as? ScheduledLearningService
        }.first
      )
      await learning.waitForPendingWork()
      #expect(try builder.stores.learning.evaluation(runId: backlog.runId)?.outcome == .noIssue)
      daemon.cancel()
      _ = await daemon.result
      #expect(await llm.recorded.count == 1)
      let writer = try DatabaseQueue(path: EnvironmentLoader.databasePath(config: config))
      let usage = try writer.read { db in
        try Row.fetchAll(
          db,
          sql: "SELECT * FROM provider_usage WHERE learning_operation_id IS NOT NULL"
        )
      }
      #expect(usage.count == 1)
      #expect(usage.first?["prompt_tokens"] as Int? == 100)
      #expect(usage.first?["completion_tokens"] as Int? == 20)
      #expect((usage.first?["cost_usd"] as Double? ?? 0) > 0)
    } catch {
      release.open()
      daemon.cancel()
      _ = await daemon.result
      throw error
    }
  }
}

// MARK: - Persisted Backlog

private extension LearningStartupTests {
  static func commitBacklog(
    stores: ClawStores,
    route: String
  ) throws -> (jobId: Int64, runId: Int64) {
    let now = LearningAcceptanceHarness.now
    let job = try stores.scheduledJobs.create(
      NewScheduledJob(
        ownerChatId: LearningAcceptanceHarness.owner,
        label: "digest",
        prompt: "Summarize material changes.",
        recurrence: SchedulingRuleFixtures.weekdayEnvelope(zone: .gmt),
        timezone: "UTC",
        nextOccurrence: now.addingTimeInterval(86_400)
      ),
      now: now
    )
    guard case .fired(let fire) = try stores.scheduledJobs.fireNow(jobId: job.id, now: now) else {
      throw StoreError.unexpected("expected eligible scheduled fire")
    }
    _ = try stores.runs.pickUp(runId: fire.runId, now: now)
    try stores.learning.freezeCompatibility(
      runId: fire.runId,
      surface: RunSurface(
        toolCatalogDigest: "tools-v1",
        policyVersion: "policy-v1",
        skillSetDigest: "skills-v1",
        configuredRoute: route
      )
    )
    let answer = LearningAcceptanceHarness.answer
    _ = try stores.runs.commitAssistantTurn(
      AssistantTurn(
        runId: fire.runId,
        sessionId: fire.sessionId,
        chatId: LearningAcceptanceHarness.owner,
        content: answer,
        usage: usageFixture(sessionId: fire.sessionId, runId: fire.runId),
        chunks: [
          OutboxChunk(
            stepIndex: 0,
            chatId: LearningAcceptanceHarness.owner,
            payload: answer,
            payloadHash: ContentHash.fnv1a(answer)
          )
        ]
      ),
      now: now
    )
    return (job.id, fire.runId)
  }
}
