import ClawAgent
import ClawData
import ClawLLM
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawCore
@testable import ClawGateway
@testable import clawd

struct LearningAcceptanceHarness {
  static let lesson = "Report only material changes."
  static let answer = "The result is unchanged."
  static let owner: Int64 = 777
  static let now = Date(timeIntervalSince1970: 1_782_000_600)
  static let noIssue = #"{"schema_version":1,"outcome":"no_issue","issue_codes":[]}"#
  static let negative =
    #"{"schema_version":1,"outcome":"reusable_issue","issue_codes":["material.missed"]}"#
  static let candidate =
    #"{"schema_version":1,"candidate":{"lessons":["Report only material changes."]}}"#

  let config: AppConfig
  let stores: ClawStores
  let writer: DatabaseQueue
  let llm: ScriptedHTTPExecutor
  let telegram: ScriptedHTTPExecutor
  let updates: LearningAcceptanceUpdates
  let bundle: DaemonRuntimeBundle
  let scheduler: SchedulerService
  let outbox: OutboxDispatcher<ContinuousClock>
  let learning: ScheduledLearningService?
  let pollerTask: Task<Void, Never>
  let jobId: Int64

  static func withHarness(
    learningEnabled: Bool,
    negativeTrial: Bool = false,
    body: (LearningAcceptanceHarness) async throws -> Void
  ) async throws {
    let env = try await make(learningEnabled: learningEnabled, negativeTrial: negativeTrial)
    do {
      try await body(env)
      await env.stop()
      try FileManager.default.removeItem(at: env.config.stateRoot)
    } catch {
      await env.stop()
      try? FileManager.default.removeItem(at: env.config.stateRoot)
      throw error
    }
  }

  static func make(
    learningEnabled: Bool,
    negativeTrial: Bool = false,
    config existingConfig: AppConfig? = nil,
    jobId existingJob: Int64? = nil
  ) async throws -> Self {
    var environment = CompositionAcceptanceHarness.validEnv()
    environment[AppConfig.EnvKey.learningEnabled] = learningEnabled ? "true" : nil
    environment[AppConfig.EnvKey.llmStreaming] = "false"
    let config = try existingConfig ?? AppConfig.load(environment: environment)
    let updates = LearningAcceptanceUpdates()
    let response: ScriptedHTTPExecutor.Step = .responding { request in
      if request.url.hasSuffix("/getUpdates") {
        return try await updates.next()
      }
      let json =
        request.url.hasSuffix("/sendMessage")
        ? #"{"ok":true,"result":{"message_id":900,"chat":{"id":777}}}"#
        : #"{"ok":true,"result":true}"#
      return HTTPResult(statusCode: 200, headers: [:], body: Data(json.utf8))
    }
    let telegram = ScriptedHTTPExecutor(Array(repeating: response, count: 128))
    let replies =
      existingJob == nil
      ? [
        answer, noIssue, candidate, answer, negativeTrial ? negative : noIssue,
        answer, noIssue,
      ]
      : [answer, noIssue]
    let llm = ScriptedHTTPExecutor(try replies.map(completion))
    var builder = try CompositionAcceptance.makeBuilder(
      http: telegram,
      config: config,
      secrets: Secrets(telegramBotToken: "tg-token", llmApiKey: "sk-test")
    )
    builder.now = { Self.now }
    try builder.stores.allowlist.seedAllowlist(userIds: [owner])
    let roster = try builder.makeRosterStack(http: llm)
    let bundle = try await builder.build(
      rosterStack: roster,
      cooldown: PrimaryRouteCooldown(
        longSeconds: config.llm.primaryCooldownSeconds,
        clock: ContinuousClock()
      )
    )
    let scheduler = try #require(
      bundle.daemon.services.compactMap { $0 as? SchedulerService }.first
    )
    let outbox = try #require(
      bundle.daemon.services.compactMap { $0 as? OutboxDispatcher<ContinuousClock> }.first
    )
    let poller = try #require(
      bundle.daemon.services.compactMap { $0 as? TelegramPollerService }.first
    )
    let learning = bundle.daemon.services.compactMap { $0 as? ScheduledLearningService }.first
    let jobId: Int64
    if let existingJob {
      jobId = existingJob
      await builder.bootReconcile(heartbeatOwner: nil)()
      await learning?.reconcileAtBoot(now: Self.now)
    } else {
      let now = Self.now
      jobId = try builder.stores.scheduledJobs.create(
        NewScheduledJob(
          ownerChatId: owner,
          label: "digest",
          prompt: "Summarize material changes.",
          recurrence: SchedulingRuleFixtures.weekdayEnvelope(zone: .gmt),
          timezone: "UTC",
          nextOccurrence: now
        ),
        now: now
      ).id
    }
    return Self(
      config: config,
      stores: builder.stores,
      writer: try DatabaseQueue(
        path: EnvironmentLoader.databasePath(config: config),
        configuration: ClawDatabase.makeConfiguration()
      ),
      llm: llm,
      telegram: telegram,
      updates: updates,
      bundle: bundle,
      scheduler: scheduler,
      outbox: outbox,
      learning: learning,
      pollerTask: Task {
        do {
          try await poller.run()
        } catch {
          if !Task.isCancelled { Issue.record(error) }
        }
      },
      jobId: jobId
    )
  }

  func stop() async {
    pollerTask.cancel()
    await pollerTask.value
    await learning?.waitForPendingWork()
  }

  func withRestarted(body: (Self) async throws -> Void) async throws {
    await stop()
    let restarted = try await Self.make(learningEnabled: true, config: config, jobId: jobId)
    do {
      try await body(restarted)
      await restarted.stop()
    } catch {
      await restarted.stop()
      throw error
    }
  }

  func fireScheduledRun() async throws -> Int64 {
    await scheduler.tick()
    return try await completedRun()
  }

  func runNow() async throws -> Int64 {
    try await submit(message: "/runnow \(jobId)")
    return try await completedRun()
  }

  func completedRun() async throws -> Int64 {
    let job = try #require(try stores.scheduledJobs.job(id: jobId))
    let sessionId = try #require(job.sessionId)
    let complete = AsyncGate()
    _ = await bundle.lanes.enqueue(sessionID: sessionId, runID: Int64.max) {
      complete.open()
    }
    await complete.wait()
    await learning?.waitForPendingWork()
    return try await writer.read { db in
      try #require(
        try Int64.fetchOne(
          db,
          sql: "SELECT MAX(id) FROM runs WHERE job_id = ?",
          arguments: [jobId]
        )
      )
    }
  }

  func correct(runId: Int64) async throws {
    let nonce = try await writer.read { db in
      try #require(
        try String.fetchOne(
          db,
          sql: "SELECT nonce FROM feedback_targets WHERE subject_kind = ? AND subject_digest = ?",
          arguments: [FeedbackSubjectKind.run.rawValue, String(runId)]
        )
      )
    }
    let data = FeedbackKeyboard.callbackData(nonce: nonce, action: .resultCorrection)
    let callback: [String: Any] = [
      "callback_query": [
        "id": "correction", "from": ["id": Self.owner], "data": data,
        "message": ["message_id": 900, "chat": ["id": Self.owner, "type": "private"]],
      ]
    ]
    try await submit(update: callback)
    try await submit(message: "Ignore counter-only changes.")
    await learning?.waitForPendingWork()
  }

  func submit(message: String) async throws {
    try await submit(update: [
      "message": [
        "message_id": 1000, "from": ["id": Self.owner],
        "chat": ["id": Self.owner, "type": "private"], "text": message,
      ]
    ])
  }

  func submit(update: [String: Any]) async throws {
    let id = (try stores.cursor.loadCursor() ?? 0) + 1
    var raw = update
    raw["update_id"] = id
    let bytes = try JSONSerialization.data(withJSONObject: ["ok": true, "result": [raw]])
    await updates.submit(bytes)
    let handled = try await pollUntilTrue {
      try stores.cursor.loadCursor() == id
    }
    #expect(handled)
  }

  func learningRowCounts() throws -> [Int] {
    try writer.read { db in
      let tables = try String.fetchAll(
        db,
        sql: """
          SELECT name FROM sqlite_master WHERE type = 'table' AND
            (name LIKE 'learning_%' OR name LIKE 'feedback_%' OR name IN (
              'job_learning_state', 'lesson_sets', 'run_learning_bindings', 'run_compatibility',
              'run_settlements', 'trial_assignments'))
          """
      )
      return try tables.map { table in
        try #require(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)"))
      }
    }
  }

  func runState(_ runId: Int64) throws -> RunState? {
    try writer.read { db in
      try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?", arguments: [runId])
        .flatMap(RunState.init(rawValue:))
    }
  }
}

// MARK: - Scripted Wire Replies

extension LearningAcceptanceHarness {
  static func completion(_ content: String) throws -> ScriptedHTTPExecutor.Step {
    let object: [String: Any] = [
      "id": "reply", "object": "chat.completion", "model": "gpt-4o",
      "choices": [
        ["message": ["role": "assistant", "content": content], "finish_reason": "stop"]
      ],
      "usage": ["prompt_tokens": 100, "completion_tokens": 20, "total_tokens": 120],
    ]
    return .ok(
      HTTPResult(
        statusCode: 200,
        headers: [:],
        body: try JSONSerialization.data(withJSONObject: object)
      )
    )
  }
}

actor LearningAcceptanceUpdates {
  private var queued: [Data] = []
  private var ready = AsyncGate()

  func submit(_ bytes: Data) {
    queued.append(bytes)
    ready.open()
  }

  func next() async throws -> HTTPResult {
    while queued.isEmpty {
      await ready.wait()
      try Task.checkCancellation()
    }
    let bytes = queued.removeFirst()
    if queued.isEmpty { ready = AsyncGate() }
    return HTTPResult(statusCode: 200, headers: [:], body: bytes)
  }
}
