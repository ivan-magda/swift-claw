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

/// A `RunStore` whose first write reports a full disk, to exercise the storage-full rethrow.
struct DiskFullRuns: RunStore {
  func pickUp(runId: Int64, now: Date) throws -> Bool { throw StoreError.diskFull }
  func commitAssistantTurn(_ turn: AssistantTurn, now: Date) throws {}
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
    runs: (any RunStore)? = nil
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
      runs: runs ?? RunStoreGRDB(writer: queue),
      usageStore: usage,
      outbox: outbox,
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
}
