// swiftlint:disable function_body_length
import ClawAgent
import ClawCore
import ClawData
import Foundation
import GRDB
import Logging
import Testing

@testable import ClawGateway

// MARK: - Test doubles

/// The real `AgentRuntime` calls this; it records the assembled message count (so the multi-turn
/// test can assert history was threaded in) and returns a scripted outcome — a canned answer or a
/// provider error — so each acceptance test drives the turn down a chosen branch.
actor RecordingProvider: LLMProvider {
  enum Outcome: Sendable {
    case respond(String)
    case fail(ProviderError)
  }

  private let outcome: Outcome
  private(set) var lastMessageCount = 0

  init(_ outcome: Outcome) { self.outcome = outcome }

  func complete(request: ChatRequest) async throws -> ChatResponse {
    lastMessageCount = request.messages.count
    switch outcome {
    case .respond(let answer):
      return ChatResponse(
        content: answer,
        finishReason: "stop",
        usage: ChatUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15),
        costFromProvider: 0.0021
      )
    case .fail(let error):
      throw error
    }
  }
}

// MARK: - Stack

/// The full inline-turn wiring over one `DatabaseWriter`: `router.handle` runs a turn and commits
/// (without sending); `dispatcher.drainOnce()` then delivers the PENDING outbox rows. Both the stores
/// and the raw `writer` are exposed so tests can assert durable state directly.
struct Stack {
  let router: MessageRouter
  let dispatcher: OutboxDispatcher
  let transport: RecordingTransport
  let provider: RecordingProvider
  let signal: OutboxSignal
  let writer: any DatabaseWriter
  let sessionMessages: SessionMessageStoreGRDB
  let runs: RunStoreGRDB
  let usage: UsageStoreGRDB
  let outbox: OutboxStoreGRDB
  let cursor: UpdateCursorStoreGRDB
  let chatId: Int64
}

/// Assembles the production inline-turn stack over `writer`, seeding `chatId` onto the allowlist and
/// scripting the provider with `outcome`. The caller owns `writer` (an in-memory queue for most tests,
/// a file pool for the restart test) and must have migrated it first.
func makeStack(
  writer: any DatabaseWriter,
  allow chatId: Int64 = 42,
  outcome: RecordingProvider.Outcome
) throws -> Stack {
  let allowlist = AllowlistStoreGRDB(writer: writer)
  try allowlist.seedAllowlist(userIds: [chatId])

  let processed = ProcessedUpdateStoreGRDB(writer: writer)
  let cursor = UpdateCursorStoreGRDB(writer: writer)
  let sessionMessages = SessionMessageStoreGRDB(writer: writer)
  let runs = RunStoreGRDB(writer: writer)
  let usage = UsageStoreGRDB(writer: writer)
  let outbox = OutboxStoreGRDB(writer: writer)
  let audit = AuditLogGRDB(writer: writer)

  let provider = RecordingProvider(outcome)
  let transport = RecordingTransport()
  let signal = OutboxSignal()
  let logger = Logger(label: "inc1-acceptance")

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

  let turnRunner = TurnRunner(
    sessionMessages: sessionMessages,
    runs: runs,
    usageStore: usage,
    outbox: outbox,
    audit: audit,
    agent: agent,
    budget: .default,
    systemPrompt: SystemPrompt.minimal,
    notifyOutbox: { signal.poke() },
    breaker: BudgetBreaker(budget: .default),
    transport: transport,
    logger: logger
  )

  let router = MessageRouter(
    processed: processed,
    sessionMessages: sessionMessages,
    accessControl: AccessControl(allowlist: allowlist),
    transport: transport,
    turnRunner: turnRunner,
    logger: logger
  )

  let dispatcher = OutboxDispatcher(
    outbox: outbox,
    transport: transport,
    signal: signal,
    logger: logger
  )

  return Stack(
    router: router,
    dispatcher: dispatcher,
    transport: transport,
    provider: provider,
    signal: signal,
    writer: writer,
    sessionMessages: sessionMessages,
    runs: runs,
    usage: usage,
    outbox: outbox,
    cursor: cursor,
    chatId: chatId
  )
}

@Suite struct LLMTurnPersistenceAcceptanceTests {
  // MARK: - Durable-state probes

  /// The most recently inserted run's `state` — DONE / FAILED / RUNNING.
  private func latestRunState(_ writer: any DatabaseWriter) throws -> String? {
    try writer.read { db in
      try String.fetchOne(db, sql: "SELECT state FROM runs ORDER BY id DESC LIMIT 1")
    }
  }

  /// Row count of one table — used to assert the turn left exactly the expected durable footprint.
  private func rowCount(_ writer: any DatabaseWriter, in table: String) throws -> Int {
    try writer.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
    }
  }

  // MARK: - Tests

  /// §1: a real answer is persisted across the whole spine and committed BEFORE any send — the turn
  /// leaves a DONE run, one usage row, an audit trail, and a single PENDING outbox row, while the
  /// transport stays silent; only the dispatcher's drain delivers it (richly).
  @Test func turnPersistsEverythingThenDelivers() async throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let stack = try makeStack(writer: queue, outcome: .respond("stub answer"))

    // when — route one allowlisted message: the turn runs inline and commits, but sends nothing
    let outcome = await stack.router.handle(
      rawUpdate: textUpdate(id: 1, from: stack.chatId, text: "hello")
    )

    // then — everything is durable, nothing is on the wire yet
    #expect(outcome == .processed)
    #expect(try latestRunState(queue) == "DONE")
    #expect(try rowCount(queue, in: "provider_usage") == 1)
    #expect(try rowCount(queue, in: "audit_events") >= 1)
    #expect(try stack.outbox.pendingOutbound().count == 1)
    #expect(await stack.transport.richSends.isEmpty)
    #expect(await stack.transport.sent.isEmpty)

    // when — the dispatcher drains the outbox
    await stack.dispatcher.drainOnce()

    // then — the answer is delivered richly (no plain fallback) and nothing stays PENDING
    #expect(await stack.transport.richSends.first?.markdown == "stub answer")
    #expect(await stack.transport.sent.isEmpty)
    #expect(try stack.outbox.pendingOutbound().isEmpty)
  }

  /// §1: the conversation is multi-turn — the second turn assembles the prior turn's user message and
  /// the committed assistant reply, so the provider sees four messages (system + user₁ + assistant +
  /// user₂), proving recent history is threaded back within the context budget.
  @Test func secondTurnSeesPriorHistory() async throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let stack = try makeStack(writer: queue, outcome: .respond("stub answer"))

    // when — two sequential turns from the same chat (distinct update ids)
    await stack.router.handle(rawUpdate: textUpdate(id: 1, from: stack.chatId, text: "first"))
    await stack.router.handle(rawUpdate: textUpdate(id: 2, from: stack.chatId, text: "second"))

    // then — the second call's request carried the full prior history plus the system prompt
    #expect(await stack.provider.lastMessageCount == 4)
  }

  /// §1: a provider outage that survives retries degrades to a plain-language message rather than
  /// silence — the run is FAILED and the owner still receives the canned "couldn't reach the model"
  /// reply through the outbox.
  @Test func providerOutageDegradesGracefully() async throws {
    // given — every attempt fails retryably, so the agent exhausts retries and degrades
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let stack = try makeStack(
      writer: queue,
      outcome: .fail(.retryable(status: 503, message: "down"))
    )

    // when
    await stack.router.handle(rawUpdate: textUpdate(id: 1, from: stack.chatId, text: "hello"))
    await stack.dispatcher.drainOnce()

    // then — the run failed but the owner was told, never left silent
    #expect(try latestRunState(queue) == "FAILED")
    #expect(await stack.transport.richSends.first?.markdown == Degradation.providerUnavailable)
  }

  /// §1: when today's spend already meets the daily cap, the offline gate refuses BEFORE any provider
  /// call and the owner gets a plain stop message — the breaker is enforced from durable
  /// `provider_usage`, not the live call.
  @Test func dailyCapStopsTheTurnWithAMessage() async throws {
    // given — seed today's usage at the daily USD cap against a throwaway run, so the FK holds and
    // the running total (global per UTC day) already sits at the limit
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let stack = try makeStack(writer: queue, outcome: .respond("should never be produced"))

    let seedClaim = try stack.sessionMessages.claimAndPersistInbound(
      InboundMessage(
        updateId: 900,
        sessionKey: SessionKey.telegramDM(chatId: 999),
        chatId: 999,
        userId: 999,
        text: "seed",
        isEdited: false,
        ts: Date()
      )
    )
    let seedSession = try #require(seedClaim.sessionId)
    let seedRun = try stack.runs.createRun(sessionId: seedSession, now: Date())
    try stack.usage.recordUsage(
      ProviderUsage(
        runId: seedRun,
        sessionId: seedSession,
        model: "gpt-4o",
        promptTokens: 0,
        completionTokens: 0,
        costUSD: RunBudget.default.perDayUSD,
        costSource: .providerReturned,
        isEstimated: false,
        ts: Date()
      )
    )

    // when — an allowlisted turn arrives with the cap already met
    await stack.router.handle(rawUpdate: textUpdate(id: 1, from: stack.chatId, text: "hello"))
    await stack.dispatcher.drainOnce()

    // then — the gate refused pre-call (provider never invoked), the run failed, and the owner was told
    #expect(await stack.provider.lastMessageCount == 0)
    #expect(try latestRunState(queue) == "FAILED")
    #expect(
      await stack.transport.richSends.first?.markdown == Degradation.budget(cap: "per-day spend")
    )
  }

  /// §1: the conversation survives a restart. A turn processed against a file-backed pool, with the
  /// cursor advanced, is fully recoverable after reopening the same file: the offset persists and
  /// both the user message and the committed assistant reply are still in history.
  @Test func cursorAndHistorySurviveRestart() async throws {
    // given — a file-backed pool so the state outlives the "process"
    let path = NSTemporaryDirectory() + "claw-restart-\(UInt64.random(in: 0..<(.max))).sqlite"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let sessionKey = SessionKey.telegramDM(chatId: 42)

    // when — first run: process a turn, then advance the cursor (the poller's last step). The scope
    // releases the pool, modeling the process exiting.
    do {
      let pool = try ClawDatabase.makePool(path: path)
      try ClawDatabase.migrate(pool)
      let stack = try makeStack(writer: pool, outcome: .respond("stub answer"))
      await stack.router.handle(rawUpdate: textUpdate(id: 100, from: stack.chatId, text: "hello"))
      try stack.cursor.advanceCursor(to: 100)
    }

    // then — restart: fresh stores on the same file recover the cursor and the conversation
    let reopened = try ClawDatabase.openStores(path: path)
    #expect(try reopened.cursor.loadCursor() == 100)

    let sessionId = try reopened.sessionMessages.loadOrCreateSession(
      sessionKey: sessionKey,
      now: Date()
    )
    let history = try reopened.sessionMessages.loadRecentMessages(sessionId: sessionId, limit: 50)
    #expect(history.contains { $0.role == .user && $0.content == "hello" })
    #expect(history.contains { $0.role == .assistant && $0.content == "stub answer" })
  }
}
// swiftlint:enable function_body_length
