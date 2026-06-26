import ClawAgent
import ClawCore
import ClawData
import Foundation
import GRDB
import Logging
import Testing

@testable import ClawGateway

// MARK: - Test doubles

/// Drives `AgentRuntime` to a chosen `TurnResult` by scripting the provider it calls.
actor StubLLMProvider: LLMProvider {
  enum Outcome: Sendable {
    case respond(ChatResponse)
    case fail(ProviderError)
  }

  private let outcome: Outcome
  private(set) var callCount = 0

  init(_ outcome: Outcome) { self.outcome = outcome }

  func complete(request: ChatRequest) async throws -> ChatResponse {
    callCount += 1
    switch outcome {
    case .respond(let response): return response
    case .fail(let error): throw error
    }
  }
}

struct NoopTyping: TypingIndicator {
  func sendTyping(chatId: Int64) async {}
}

/// Delegates to the real run store but flips the active run to CANCELLED immediately before the
/// assistant commit, modeling `/stop` winning after the provider returned usage.
struct CancellingBeforeAssistantCommitRuns: RunStore {
  let base: RunStoreGRDB
  let sessionId: Int64

  func pickUp(runId: Int64, now: Date) throws -> Bool {
    try base.pickUp(runId: runId, now: now)
  }

  func commitAssistantTurn(_ turn: AssistantTurn, now: Date) throws -> RunCommitResult {
    _ = try base.cancelActiveRun(sessionId: sessionId, reason: .cancelled, now: now)
    return try base.commitAssistantTurn(turn, now: now)
  }

  func commitDegradedTurn(_ turn: DegradedTurn, now: Date) throws -> RunCommitResult {
    try base.commitDegradedTurn(turn, now: now)
  }

  func failRun(runId: Int64, now: Date) throws {
    try base.failRun(runId: runId, now: now)
  }

  func cancelActiveRun(sessionId: Int64, reason: CancelReason, now: Date) throws -> Int64? {
    try base.cancelActiveRun(sessionId: sessionId, reason: reason, now: now)
  }

  func supersedeSessionRuns(sessionId: Int64, now: Date) throws -> [Int64] {
    try base.supersedeSessionRuns(sessionId: sessionId, now: now)
  }

  func reconcileRunsAtBoot(now: Date, degradationText: String) throws -> [DegradationReply] {
    try base.reconcileRunsAtBoot(now: now, degradationText: degradationText)
  }

  func runsHealth(now: Date) throws -> RunsHealth {
    try base.runsHealth(now: now)
  }
}

/// Delegates to the real run store but flips the active run to CANCELLED immediately before the
/// degradation commit, modeling `/stop` winning after the runtime produced a degradation result.
struct CancellingBeforeDegradedCommitRuns: RunStore {
  let base: RunStoreGRDB
  let sessionId: Int64

  func pickUp(runId: Int64, now: Date) throws -> Bool {
    try base.pickUp(runId: runId, now: now)
  }

  func commitAssistantTurn(_ turn: AssistantTurn, now: Date) throws -> RunCommitResult {
    try base.commitAssistantTurn(turn, now: now)
  }

  func commitDegradedTurn(_ turn: DegradedTurn, now: Date) throws -> RunCommitResult {
    _ = try base.cancelActiveRun(sessionId: sessionId, reason: .cancelled, now: now)
    return try base.commitDegradedTurn(turn, now: now)
  }

  func failRun(runId: Int64, now: Date) throws {
    try base.failRun(runId: runId, now: now)
  }

  func cancelActiveRun(sessionId: Int64, reason: CancelReason, now: Date) throws -> Int64? {
    try base.cancelActiveRun(sessionId: sessionId, reason: reason, now: now)
  }

  func supersedeSessionRuns(sessionId: Int64, now: Date) throws -> [Int64] {
    try base.supersedeSessionRuns(sessionId: sessionId, now: now)
  }

  func reconcileRunsAtBoot(now: Date, degradationText: String) throws -> [DegradationReply] {
    try base.reconcileRunsAtBoot(now: now, degradationText: degradationText)
  }

  func runsHealth(now: Date) throws -> RunsHealth {
    try base.runsHealth(now: now)
  }
}

/// A `RunStore` whose first write reports a full disk, to exercise the storage-full rethrow.
struct DiskFullRuns: RunStore {
  func pickUp(runId: Int64, now: Date) throws -> Bool { throw StoreError.diskFull }
  func commitAssistantTurn(_ turn: AssistantTurn, now: Date) throws -> RunCommitResult { .ignored }
  func commitDegradedTurn(_ turn: DegradedTurn, now: Date) throws -> RunCommitResult { .ignored }
  func failRun(runId: Int64, now: Date) throws {}
  func cancelActiveRun(sessionId: Int64, reason: CancelReason, now: Date) throws -> Int64? { nil }
  func supersedeSessionRuns(sessionId: Int64, now: Date) throws -> [Int64] { [] }
  func reconcileRunsAtBoot(now: Date, degradationText: String) throws -> [DegradationReply] { [] }
  func runsHealth(now: Date) throws -> RunsHealth {
    RunsHealth(
      inFlight: 0,
      oldestRunAgeSeconds: nil,
      lastFailedAt: nil,
      lastSuccessAt: nil,
      consecutiveFailures: 0
    )
  }
}

@Suite struct TurnRunnerTests {
  private struct Env {
    let runner: TurnRunner
    let queue: DatabaseQueue
    let sessionMessages: SessionMessageStoreGRDB
    let outbox: OutboxStoreGRDB
    let sessionId: Int64
    let chatId: Int64
    let runId: Int64
    let triggerMessageId: Int64
    let provider: StubLLMProvider
  }

  private func makeEnv(
    agentOutcome: StubLLMProvider.Outcome,
    runs: (any RunStore)? = nil,
    runsFactory: ((DatabaseQueue, Int64) -> any RunStore)? = nil
  ) throws -> Env {
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)

    let sessionMessages = SessionMessageStoreGRDB(writer: queue)
    let usage = UsageStoreGRDB(writer: queue)
    let outbox = OutboxStoreGRDB(writer: queue)
    let audit = AuditLogGRDB(writer: queue)

    // Seed a session + a user message via the real fused claim, so history is realistic.
    let chatId: Int64 = 42
    let claim = try sessionMessages.claimAndPersistInbound(
      InboundMessage(
        updateId: 1,
        sessionKey: SessionKey.telegramDM(chatId: chatId),
        chatId: chatId,
        userId: chatId,
        text: "hi",
        isEdited: false,
        ts: Date()
      )
    )
    let sessionId = try #require(claim.sessionId)
    let runId = try #require(claim.runId)
    let triggerMessageId = try #require(claim.triggerMessageId)

    let provider = StubLLMProvider(agentOutcome)
    let agent = AgentRuntime(
      provider: provider,
      typingIndicator: NoopTyping(),
      costResolver: CostResolver(
        priceTable: .empty,
        referenceUSDPerToken: RunBudget.default.referenceUSDPerToken
      ),
      budget: .default,
      model: "gpt-4o",
      sleep: { try await Task.sleep(for: $0) }
    )

    let runner = TurnRunner(
      sessionMessages: sessionMessages,
      runs: runsFactory?(queue, sessionId) ?? runs ?? RunStoreGRDB(writer: queue),
      usageStore: usage,
      audit: audit,
      agent: agent,
      budget: .default,
      systemPrompt: SystemPrompt.minimal,
      notifyOutbox: {},
      logger: Logger(label: "test")
    )

    return Env(
      runner: runner,
      queue: queue,
      sessionMessages: sessionMessages,
      outbox: outbox,
      sessionId: sessionId,
      chatId: chatId,
      runId: runId,
      triggerMessageId: triggerMessageId,
      provider: provider
    )
  }

  private func latestRunState(_ queue: DatabaseQueue) throws -> String? {
    try queue.read { db in
      try String.fetchOne(db, sql: "SELECT state FROM runs ORDER BY id DESC LIMIT 1")
    }
  }

  private func okResponse(content: String) -> ChatResponse {
    ChatResponse(
      content: content,
      finishReason: "stop",
      usage: ChatUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15),
      costFromProvider: 0.0021
    )
  }

  @Test func completedTurnCommitsDoneRunAndEnqueuesOneOutboxRow() async throws {
    // given
    let env = try makeEnv(agentOutcome: .respond(okResponse(content: "Hello there")))

    // when
    try await env.runner.run(
      runId: env.runId,
      sessionId: env.sessionId,
      chatId: env.chatId,
      triggerMessageId: env.triggerMessageId
    )

    // then
    #expect(try latestRunState(env.queue) == "DONE")
    let persistedAssistantCount = try await env.queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM messages WHERE run_id = ? AND content = ?",
        arguments: [env.runId, "Hello there"]
      )
    }
    let assistantCount = try #require(persistedAssistantCount)
    #expect(assistantCount == 1)
    let pending = try env.outbox.pendingOutbound()
    #expect(pending.count == 1)
    let firstPending = try #require(pending.first)
    #expect(firstPending.payload == "Hello there")
  }

  @Test func degradedTurnFailsRunAndEnqueuesADegradationReply() async throws {
    // given — a terminal provider error: no usable answer, no usage to debit
    let env = try makeEnv(agentOutcome: .fail(.terminal(status: 400, message: "bad request")))

    // when
    try await env.runner.run(
      runId: env.runId,
      sessionId: env.sessionId,
      chatId: env.chatId,
      triggerMessageId: env.triggerMessageId
    )

    // then
    #expect(try latestRunState(env.queue) == "FAILED")
    let pending = try env.outbox.pendingOutbound()
    #expect(pending.count == 1)
    let firstPending = try #require(pending.first)
    #expect(firstPending.payload == Degradation.providerUnavailable)
  }

  @Test func diskFullDuringCommitIsRethrownForTheStorageFullPath() async throws {
    // given — the run's first write reports a full disk
    let env = try makeEnv(
      agentOutcome: .respond(okResponse(content: "ignored")),
      runs: DiskFullRuns()
    )

    // when / then — only StoreError.diskFull may propagate out of run
    await #expect(throws: StoreError.diskFull) {
      try await env.runner.run(
        runId: env.runId,
        sessionId: env.sessionId,
        chatId: env.chatId,
        triggerMessageId: env.triggerMessageId
      )
    }
  }

  @Test func supersededRunSelfAbortsBeforeProviderCall() async throws {
    // given
    let env = try makeEnv(agentOutcome: .respond(okResponse(content: "should not run")))
    _ = try RunStoreGRDB(writer: env.queue).supersedeSessionRuns(
      sessionId: env.sessionId,
      now: Date()
    )

    // when
    try await env.runner.run(
      runId: env.runId,
      sessionId: env.sessionId,
      chatId: env.chatId,
      triggerMessageId: env.triggerMessageId
    )

    // then
    #expect(await env.provider.callCount == 0)
    #expect(try latestRunState(env.queue) == RunState.superseded.rawValue)
    #expect(try env.outbox.pendingOutbound().isEmpty)
  }

  @Test func completedUsageSurvivesWhenStopWinsBeforeAssistantCommit() async throws {
    // given
    let env = try makeEnv(
      agentOutcome: .respond(okResponse(content: "must not send")),
      runsFactory: { queue, sessionId in
        CancellingBeforeAssistantCommitRuns(
          base: RunStoreGRDB(writer: queue),
          sessionId: sessionId
        )
      }
    )

    // when
    try await env.runner.run(
      runId: env.runId,
      sessionId: env.sessionId,
      chatId: env.chatId,
      triggerMessageId: env.triggerMessageId
    )

    // then
    let state = try #require(
      try await env.queue.read { db in
        try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?", arguments: [env.runId])
      }
    )
    let usageCount = try #require(
      try await env.queue.read { db in
        try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM provider_usage WHERE run_id = ?",
          arguments: [env.runId]
        )
      }
    )
    let assistantCount = try #require(
      try await env.queue.read { db in
        try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM messages WHERE run_id = ? AND role = 'assistant'",
          arguments: [env.runId]
        )
      }
    )
    #expect(state == RunState.cancelled.rawValue)
    #expect(usageCount == 1)
    #expect(assistantCount == 0)
    #expect(try env.outbox.pendingOutbound().isEmpty)
  }

  @Test func degradationReplyIsNotLeftPendingWhenStopWinsBeforeFailCommit() async throws {
    // given
    let raced = try makeEnv(
      agentOutcome: .fail(.terminal(status: 400, message: "bad request")),
      runsFactory: { queue, sessionId in
        CancellingBeforeDegradedCommitRuns(
          base: RunStoreGRDB(writer: queue),
          sessionId: sessionId
        )
      }
    )

    // when
    try await raced.runner.run(
      runId: raced.runId,
      sessionId: raced.sessionId,
      chatId: raced.chatId,
      triggerMessageId: raced.triggerMessageId
    )

    // then
    #expect(try latestRunState(raced.queue) == RunState.cancelled.rawValue)
    #expect(try raced.outbox.pendingOutbound().isEmpty)
  }
}
