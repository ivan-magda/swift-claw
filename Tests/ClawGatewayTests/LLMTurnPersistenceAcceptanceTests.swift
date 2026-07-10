// swiftlint:disable function_body_length
import ClawAgent
import ClawCore
import ClawData
import ClawTelegram
import ClawWorkspace
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
  private let blocksFirstCall: Bool
  private(set) var requests: [[ChatMessage]] = []
  private var requestContinuations: [CheckedContinuation<Void, Never>] = []
  private var firstCallRelease: CheckedContinuation<Void, Never>?

  init(_ outcome: Outcome, blocksFirstCall: Bool = false) {
    self.outcome = outcome
    self.blocksFirstCall = blocksFirstCall
  }

  var lastMessageCount: Int {
    requests.last?.count ?? 0
  }

  func complete(request: ChatRequest) async throws -> ChatResponse {
    requests.append(request.messages)
    for continuation in requestContinuations {
      continuation.resume()
    }
    requestContinuations.removeAll()
    if blocksFirstCall && requests.count == 1 {
      await withCheckedContinuation { continuation in
        firstCallRelease = continuation
      }
    }

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

  func waitForRequestCount(_ count: Int) async {
    while requests.count < count {
      await withCheckedContinuation { continuation in
        requestContinuations.append(continuation)
      }
    }
  }

  func releaseFirstCall() {
    firstCallRelease?.resume()
    firstCallRelease = nil
  }
}

actor StreamingAcceptanceProvider: LLMProvider {
  enum StreamScript: Sendable {
    case success
    case beforeDelta(ProviderError)
    case afterDraft(ProviderError)
  }

  private(set) var completeCalls = 0
  private(set) var streamCalls = 0
  private var requestWaiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] =
    []
  private var script: StreamScript = .success
  private var postDeltaRelease: CheckedContinuation<Void, Never>?
  private var postDeltaReleased = false

  func complete(request: ChatRequest) async throws -> ChatResponse {
    completeCalls += 1
    return ChatResponse(
      content: "blocking fallback",
      finishReason: "stop",
      usage: ChatUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15),
      costFromProvider: 0.0021
    )
  }

  nonisolated func stream(request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
    AsyncThrowingStream { continuation in
      Task {
        await self.recordStreamCall()
        switch await self.currentScript() {
        case .beforeDelta(let failure):
          continuation.finish(throwing: failure)
          return
        case .success:
          continuation.yield(.delta("stream "))
          await self.waitForPostDeltaRelease()
          continuation.yield(.delta("answer"))
          continuation.yield(
            .finished(
              finishReason: "stop",
              usage: ChatUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15),
              providerCost: 0.0021,
              toolCalls: []
            )
          )
          continuation.finish()
        case .afterDraft(let failure):
          continuation.yield(.delta("stream "))
          await self.waitForPostDeltaRelease()
          continuation.finish(throwing: failure)
        }
      }
    }
  }

  func waitForStreamCalls(_ count: Int) async {
    guard streamCalls < count else { return }
    await withCheckedContinuation { continuation in
      requestWaiters.append((threshold: count, continuation: continuation))
    }
  }

  func setStreamFailure(_ failure: ProviderError?) {
    script =
      if let failure {
        .beforeDelta(failure)
      } else {
        .success
      }
    postDeltaReleased = false
    postDeltaRelease = nil
  }

  func setPostDraftFailure(_ failure: ProviderError) {
    script = .afterDraft(failure)
    postDeltaReleased = false
    postDeltaRelease = nil
  }

  func releasePostDelta() {
    postDeltaReleased = true
    postDeltaRelease?.resume()
    postDeltaRelease = nil
  }

  private func recordStreamCall() {
    streamCalls += 1
    let pending = requestWaiters
    requestWaiters = pending.filter { $0.threshold > streamCalls }
    for waiter in pending where waiter.threshold <= streamCalls {
      waiter.continuation.resume()
    }
  }

  private func currentScript() -> StreamScript {
    script
  }

  private func waitForPostDeltaRelease() async {
    guard !postDeltaReleased else { return }
    await withCheckedContinuation { continuation in
      postDeltaRelease = continuation
    }
  }
}

actor StopNewProvider: LLMProvider {
  private(set) var requests: [[ChatMessage]] = []
  private var requestContinuations: [(count: Int, continuation: CheckedContinuation<Void, Never>)] =
    []

  func complete(request: ChatRequest) async throws -> ChatResponse {
    requests.append(request.messages)
    resumeRequestContinuations()

    if requests.count == 1 {
      while !Task.isCancelled {
        try await Task.sleep(for: .milliseconds(5))
      }
      throw CancellationError()
    }

    return ChatResponse(
      content: "fresh reply",
      finishReason: "stop",
      usage: ChatUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15),
      costFromProvider: 0.0021
    )
  }

  func waitForRequestCount(_ count: Int) async {
    guard requests.count < count else { return }
    await withCheckedContinuation { continuation in
      requestContinuations.append((count: count, continuation: continuation))
    }
  }

  private func resumeRequestContinuations() {
    let currentCount = requests.count
    let ready = requestContinuations.filter { $0.count <= currentCount }
    requestContinuations.removeAll { $0.count <= currentCount }
    for waiter in ready {
      waiter.continuation.resume()
    }
  }
}

actor Gate {
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func wait() async {
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

// MARK: - Stack

/// The full lane-dispatched wiring over one `DatabaseWriter`: `router.handle` persists and enqueues;
/// the lane commits without sending, then `dispatcher.drainOnce()` delivers PENDING outbox rows.
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
  let lanes: SessionLaneRegistry
}

struct StopNewStack {
  let router: MessageRouter
  let transport: RecordingTransport
  let provider: StopNewProvider
  let signal: OutboxSignal
  let writer: any DatabaseWriter
  let outbox: OutboxStoreGRDB
  let chatId: Int64
}

struct StreamingStack {
  let router: MessageRouter
  let dispatcher: OutboxDispatcher
  let transport: RecordingTransport
  let provider: StreamingAcceptanceProvider
  let signal: OutboxSignal
  let outbox: OutboxStoreGRDB
  let chatId: Int64
}

struct AcceptanceWorkspace: WorkspaceReading {
  func load(file: WorkspaceFile, maxGraphemes: Int?) -> LoadedFile {
    .missing
  }

  func loadDailyLog(day: String, maxGraphemes: Int?) -> LoadedFile {
    .missing
  }

  func scanSkills() -> SkillScanResult {
    SkillScanResult(descriptors: [], warnings: [])
  }
}

func makeAcceptanceContextBuilder(
  writer: any DatabaseWriter,
  workspace: any WorkspaceReading = AcceptanceWorkspace()
) -> ContextBuilder {
  ContextBuilder(
    systemPrompt: SystemPrompt.minimal,
    workspace: workspace,
    memoryStore: MemoryStoreGRDB(writer: writer),
    retriever: RetrieverGRDB(writer: writer),
    budget: .default
  )
}

/// Assembles the production lane stack over `writer`, seeding `chatId` onto the allowlist and
/// scripting the provider with `outcome`.
func makeStack(
  writer: any DatabaseWriter,
  allow chatId: Int64 = 42,
  outcome: RecordingProvider.Outcome,
  blocksFirstProviderCall: Bool = false,
  workspace: any WorkspaceReading = AcceptanceWorkspace()
) throws -> Stack {
  let allowlist = AllowlistStoreGRDB(writer: writer)
  try allowlist.seedAllowlist(userIds: [chatId])

  let processed = ProcessedUpdateStoreGRDB(writer: writer)
  let cursor = UpdateCursorStoreGRDB(writer: writer)
  let sessionMessages = SessionMessageStoreGRDB(writer: writer)
  let commands = CommandStoreGRDB(writer: writer)
  let runs = RunStoreGRDB(writer: writer)
  let usage = UsageStoreGRDB(writer: writer)
  let outbox = OutboxStoreGRDB(writer: writer)
  let audit = AuditLogGRDB(writer: writer)

  let provider = RecordingProvider(outcome, blocksFirstCall: blocksFirstProviderCall)
  let transport = RecordingTransport()
  let signal = OutboxSignal()
  let lanes = SessionLaneRegistry()
  let logger = TestLog.silent

  let agent = AgentRuntime(
    provider: provider,
    typingIndicator: NoopTyping(),
    draftStreamer: NoopRichDraftStreaming(),
    streamingEnabled: false,
    costResolver: CostResolver(
      priceTable: .empty,
      referenceUSDPerToken: RunBudget.default.referenceUSDPerToken
    ),
    budget: .default,
    model: "gpt-4o",
    usageStore: usage,
    auditLog: audit,
    clock: ContinuousClock()
  )

  let turnRunner = TurnRunner(
    sessionMessages: sessionMessages,
    runs: runs,
    usageStore: usage,
    audit: audit,
    agent: agent,
    budget: .default,
    contextBuilder: makeAcceptanceContextBuilder(writer: writer, workspace: workspace),
    notifyOutbox: { signal.poke() },
    breaker: BudgetBreaker(budget: .default),
    delivery: transport,
    // Inert on purpose: these fixtures never resolve approvals, so no turn may reach a park.
    parker: InertApprovalParker(coordinator: ApprovalCoordinator()),
    logger: logger
  )

  let router = MessageRouter(
    processed: processed,
    sessionMessages: sessionMessages,
    commands: commands,
    memory: MemoryStoreGRDB(writer: writer),
    memoryCommands: MemoryCommandStoreGRDB(writer: writer),
    pendingConfirmations: PendingConfirmationRegistry(),
    botUsername: "claw_bot",
    accessControl: AccessControl(allowlist: allowlist),
    delivery: transport,
    turnRunner: turnRunner,
    lanes: lanes,
    schedule: makeIdleScheduleSurface(writer: writer),
    coordinator: ApprovalCoordinator(),
    logger: logger
  )

  let dispatcher = OutboxDispatcher(
    outbox: outbox,
    delivery: transport,
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
    chatId: chatId,
    lanes: lanes
  )
}

func makeStreamingStack(
  writer: any DatabaseWriter,
  allow chatId: Int64 = 42
) throws -> StreamingStack {
  let allowlist = AllowlistStoreGRDB(writer: writer)
  try allowlist.seedAllowlist(userIds: [chatId])
  let processed = ProcessedUpdateStoreGRDB(writer: writer)
  let sessionMessages = SessionMessageStoreGRDB(writer: writer)
  let commands = CommandStoreGRDB(writer: writer)
  let runs = RunStoreGRDB(writer: writer)
  let usage = UsageStoreGRDB(writer: writer)
  let outbox = OutboxStoreGRDB(writer: writer)
  let audit = AuditLogGRDB(writer: writer)
  let provider = StreamingAcceptanceProvider()
  let transport = RecordingTransport()
  let signal = OutboxSignal()
  let lanes = SessionLaneRegistry()
  let logger = TestLog.silent
  let draftStreamer = TelegramRichDraftStreamer(transport: transport)
  let agent = AgentRuntime(
    provider: provider,
    typingIndicator: NoopTyping(),
    draftStreamer: draftStreamer,
    streamingEnabled: true,
    costResolver: CostResolver(
      priceTable: .empty,
      referenceUSDPerToken: RunBudget.default.referenceUSDPerToken
    ),
    budget: .default,
    model: "gpt-4o",
    usageStore: usage,
    auditLog: audit,
    clock: ContinuousClock()
  )
  let turnRunner = TurnRunner(
    sessionMessages: sessionMessages,
    runs: runs,
    usageStore: usage,
    audit: audit,
    agent: agent,
    budget: .default,
    contextBuilder: makeAcceptanceContextBuilder(writer: writer),
    notifyOutbox: { signal.poke() },
    breaker: BudgetBreaker(budget: .default),
    delivery: transport,
    // Inert on purpose: these fixtures never resolve approvals, so no turn may reach a park.
    parker: InertApprovalParker(coordinator: ApprovalCoordinator()),
    logger: logger
  )
  let router = MessageRouter(
    processed: processed,
    sessionMessages: sessionMessages,
    commands: commands,
    memory: MemoryStoreGRDB(writer: writer),
    memoryCommands: MemoryCommandStoreGRDB(writer: writer),
    pendingConfirmations: PendingConfirmationRegistry(),
    botUsername: "claw_bot",
    accessControl: AccessControl(allowlist: allowlist),
    delivery: transport,
    turnRunner: turnRunner,
    lanes: lanes,
    schedule: makeIdleScheduleSurface(writer: writer),
    coordinator: ApprovalCoordinator(),
    logger: logger
  )
  let dispatcher = OutboxDispatcher(
    outbox: outbox,
    delivery: transport,
    signal: signal,
    logger: logger
  )
  return StreamingStack(
    router: router,
    dispatcher: dispatcher,
    transport: transport,
    provider: provider,
    signal: signal,
    outbox: outbox,
    chatId: chatId
  )
}

func makeStopNewStack(
  writer: any DatabaseWriter,
  allow chatId: Int64 = 42
) throws -> StopNewStack {
  let allowlist = AllowlistStoreGRDB(writer: writer)
  try allowlist.seedAllowlist(userIds: [chatId])

  let processed = ProcessedUpdateStoreGRDB(writer: writer)
  let sessionMessages = SessionMessageStoreGRDB(writer: writer)
  let commands = CommandStoreGRDB(writer: writer)
  let runs = RunStoreGRDB(writer: writer)
  let usage = UsageStoreGRDB(writer: writer)
  let outbox = OutboxStoreGRDB(writer: writer)
  let audit = AuditLogGRDB(writer: writer)

  let provider = StopNewProvider()
  let transport = RecordingTransport()
  let signal = OutboxSignal()
  let lanes = SessionLaneRegistry()
  let logger = TestLog.silent

  let agent = AgentRuntime(
    provider: provider,
    typingIndicator: NoopTyping(),
    draftStreamer: NoopRichDraftStreaming(),
    streamingEnabled: false,
    costResolver: CostResolver(
      priceTable: .empty,
      referenceUSDPerToken: RunBudget.default.referenceUSDPerToken
    ),
    budget: .default,
    model: "gpt-4o",
    usageStore: usage,
    auditLog: audit,
    clock: ContinuousClock()
  )

  let turnRunner = TurnRunner(
    sessionMessages: sessionMessages,
    runs: runs,
    usageStore: usage,
    audit: audit,
    agent: agent,
    budget: .default,
    contextBuilder: makeAcceptanceContextBuilder(writer: writer),
    notifyOutbox: { signal.poke() },
    breaker: BudgetBreaker(budget: .default),
    delivery: transport,
    // Inert on purpose: these fixtures never resolve approvals, so no turn may reach a park.
    parker: InertApprovalParker(coordinator: ApprovalCoordinator()),
    logger: logger
  )

  let router = MessageRouter(
    processed: processed,
    sessionMessages: sessionMessages,
    commands: commands,
    memory: MemoryStoreGRDB(writer: writer),
    memoryCommands: MemoryCommandStoreGRDB(writer: writer),
    pendingConfirmations: PendingConfirmationRegistry(),
    botUsername: "claw_bot",
    accessControl: AccessControl(allowlist: allowlist),
    delivery: transport,
    turnRunner: turnRunner,
    lanes: lanes,
    schedule: makeIdleScheduleSurface(writer: writer),
    coordinator: ApprovalCoordinator(),
    logger: logger
  )

  return StopNewStack(
    router: router,
    transport: transport,
    provider: provider,
    signal: signal,
    writer: writer,
    outbox: outbox,
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

  private func runStates(_ writer: any DatabaseWriter) throws -> [String] {
    try writer.read { db in
      try String.fetchAll(db, sql: "SELECT state FROM runs ORDER BY id ASC")
    }
  }

  private func waitForOutboxPoke(_ signal: OutboxSignal) async {
    var iterator = signal.notifications.makeAsyncIterator()
    _ = await iterator.next()
  }

  private func waitForRunStates(
    _ writer: any DatabaseWriter,
    expected: [String]
  ) async throws {
    _ = try await pollUntil { try runStates(writer) == expected ? expected : nil }
    #expect(try runStates(writer) == expected)
  }

  private func waitForPendingOutboxCount(
    _ outbox: OutboxStoreGRDB,
    count: Int
  ) async throws {
    _ = try await pollUntil { try outbox.pendingOutbound().count == count ? count : nil }
    #expect(try outbox.pendingOutbound().count == count)
  }

  // MARK: - Tests

  @Test func streamedTurnPublishesDraftsThenFinalizesViaOutbox() async throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let stack = try makeStreamingStack(writer: queue)

    // when
    let outcome = await stack.router.handle(
      rawUpdate: textUpdate(id: 501, from: stack.chatId, text: "stream please")
    )
    await stack.provider.waitForStreamCalls(1)
    await stack.transport.waitForDrafts(atLeast: 1)
    await stack.provider.releasePostDelta()
    try await waitForRunStates(queue, expected: [RunState.done.rawValue])

    // then
    #expect(outcome == .processed)
    let drafts = await stack.transport.drafts
    #expect(drafts.count >= 2)
    #expect(Set(drafts.map(\.draftId)).count == 1)
    #expect(drafts.last?.markdown == "stream answer")
    #expect(await stack.transport.richSends.isEmpty)
    #expect(try stack.outbox.pendingOutbound().count == 1)

    // when
    await stack.dispatcher.drainOnce()

    // then
    #expect(await stack.transport.richSends.first?.markdown == "stream answer")
    #expect(try stack.outbox.pendingOutbound().isEmpty)
  }

  @Test func streamingConnectFailureFallsBackToBlockingPath() async throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let stack = try makeStreamingStack(writer: queue)
    await stack.provider.setStreamFailure(.connectFailed(message: "refused"))

    // when
    let outcome = await stack.router.handle(
      rawUpdate: textUpdate(id: 502, from: stack.chatId, text: "fallback")
    )
    try await waitForRunStates(queue, expected: [RunState.done.rawValue])
    await stack.dispatcher.drainOnce()

    // then
    #expect(outcome == .processed)
    #expect(await stack.provider.streamCalls == 1)
    #expect(await stack.provider.completeCalls == 1)
    #expect(await stack.transport.richSends.first?.markdown == "blocking fallback")
  }

  @Test func postSendStreamingFailureDoesNotIssueBlockingFallback() async throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let stack = try makeStreamingStack(writer: queue)
    await stack.provider.setPostDraftFailure(.retryable(status: nil, message: "drop"))

    // when
    let outcome = await stack.router.handle(
      rawUpdate: textUpdate(id: 503, from: stack.chatId, text: "drop")
    )
    await stack.provider.waitForStreamCalls(1)
    await stack.transport.waitForDrafts(atLeast: 1)
    await stack.provider.releasePostDelta()
    try await waitForRunStates(queue, expected: [RunState.failed.rawValue])

    // then
    #expect(outcome == .processed)
    #expect(await stack.transport.drafts.isEmpty == false)
    #expect(await stack.provider.streamCalls == 1)
    #expect(await stack.provider.completeCalls == 0)
  }

  /// §1: a real answer is persisted across the whole spine and committed BEFORE any send — the turn
  /// leaves a DONE run, one usage row, an audit trail, and a single PENDING outbox row, while the
  /// transport stays silent; only the dispatcher's drain delivers it (richly).
  @Test func turnPersistsEverythingThenDelivers() async throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let stack = try makeStack(writer: queue, outcome: .respond("stub answer"))

    // when — route one allowlisted message, then wait for the queued turn to commit
    let outcome = await stack.router.handle(
      rawUpdate: textUpdate(id: 1, from: stack.chatId, text: "hello")
    )
    try await waitForRunStates(queue, expected: [RunState.done.rawValue])

    // then — everything is durable, nothing is on the wire yet
    #expect(outcome == .processed)
    #expect(try latestRunState(queue) == RunState.done.rawValue)
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
    try await waitForRunStates(queue, expected: [RunState.done.rawValue])
    await stack.router.handle(rawUpdate: textUpdate(id: 2, from: stack.chatId, text: "second"))
    await stack.provider.waitForRequestCount(2)
    try await waitForRunStates(
      queue,
      expected: [RunState.done.rawValue, RunState.done.rawValue]
    )

    // then — the second call threads the prior user message and the committed assistant reply
    // back alongside the new one, rather than pinning the exact assembled count
    let requests = await stack.provider.requests
    let secondContents = requests[1].map(\.content)
    #expect(secondContents.contains("first"))
    #expect(secondContents.contains("stub answer"))
    #expect(secondContents.contains("second"))
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
    try await waitForRunStates(queue, expected: [RunState.failed.rawValue])
    try await waitForPendingOutboxCount(stack.outbox, count: 1)
    await stack.dispatcher.drainOnce()

    // then — the run failed but the owner was told, never left silent
    #expect(try latestRunState(queue) == RunState.failed.rawValue)
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
    let seedRun = try #require(seedClaim.runId)
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
    _ = try stack.runs.supersedeSessionRuns(sessionId: seedSession, now: Date())

    // when — an allowlisted turn arrives with the cap already met
    await stack.router.handle(rawUpdate: textUpdate(id: 1, from: stack.chatId, text: "hello"))
    try await waitForRunStates(
      queue,
      expected: [RunState.superseded.rawValue, RunState.failed.rawValue]
    )
    try await waitForPendingOutboxCount(stack.outbox, count: 1)
    await stack.dispatcher.drainOnce()

    // then — the gate refused pre-call (provider never invoked), the run failed, and the owner was told
    #expect(await stack.provider.lastMessageCount == 0)
    #expect(try latestRunState(queue) == RunState.failed.rawValue)
    #expect(
      await stack.transport.richSends.first?.markdown
        == Degradation.budget(cap: BudgetGate.perDaySpendCap)
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
      try await waitForRunStates(pool, expected: [RunState.done.rawValue])
      try stack.cursor.advanceCursor(to: 100)
    }

    // then — restart: fresh stores on the same file recover the cursor and the conversation
    let reopened = try ClawDatabase.openStores(path: path)
    #expect(try reopened.cursor.loadCursor() == 100)

    let sessionId = try reopened.sessionMessages.loadOrCreateSession(
      sessionKey: sessionKey,
      now: Date()
    )
    let history = try reopened.sessionMessages.loadContext(
      sessionId: sessionId,
      throughMessageId: .max,
      limit: 50
    )
    #expect(history.contains { $0.role == .user && $0.content == "hello" })
    #expect(history.contains { $0.role == .assistant && $0.content == "stub answer" })
  }

  @Test func twoQuickMessagesRunFifoAndFirstContextExcludesSecond() async throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let stack = try makeStack(
      writer: queue,
      outcome: .respond("stub answer"),
      blocksFirstProviderCall: true
    )
    let sessionId = try stack.sessionMessages.loadOrCreateSession(
      sessionKey: SessionKey.telegramDM(chatId: stack.chatId),
      now: Date()
    )
    let lane = await stack.lanes.actor(for: sessionId)
    let gate = Gate()
    await lane.enqueue(runId: -1) {
      await gate.wait()
    }

    // when
    let firstOutcome = await stack.router.handle(
      rawUpdate: textUpdate(id: 1, from: stack.chatId, text: "first")
    )
    let secondOutcome = await stack.router.handle(
      rawUpdate: textUpdate(id: 2, from: stack.chatId, text: "second")
    )
    #expect(firstOutcome == .processed)
    #expect(secondOutcome == .processed)
    #expect(await stack.provider.requests.isEmpty)
    await gate.release()
    await stack.provider.waitForRequestCount(1)
    #expect(await stack.provider.requests.count == 1)
    await stack.provider.releaseFirstCall()
    await stack.provider.waitForRequestCount(2)
    try await waitForRunStates(
      queue,
      expected: [RunState.done.rawValue, RunState.done.rawValue]
    )

    // then
    let requests = await stack.provider.requests
    let firstContents = requests[0].map(\.content)
    let secondContents = requests[1].map(\.content)
    #expect(firstContents.contains("first"))
    #expect(firstContents.contains("second") == false)
    #expect(secondContents.contains("second"))
    let assistantRunIds = try await queue.read { db in
      try Int64.fetchAll(
        db,
        sql: "SELECT run_id FROM messages WHERE role = 'assistant' ORDER BY id ASC"
      )
    }
    let runIds = try await queue.read { db in
      try Int64.fetchAll(db, sql: "SELECT id FROM runs ORDER BY id ASC")
    }
    #expect(runIds.count == 2)
    #expect(assistantRunIds == runIds)  // one assistant reply per run, in run order
    #expect(assistantRunIds[0] < assistantRunIds[1])  // strictly ascending, not the literal [1, 2]
  }

  @Test func stopMidTurnCancelsRunAndNextPlainMessageStillReplies() async throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let stack = try makeStopNewStack(writer: queue)

    // when
    let firstOutcome = await stack.router.handle(
      rawUpdate: textUpdate(id: 1, from: stack.chatId, text: "before stop")
    )
    await stack.provider.waitForRequestCount(1)
    let stopOutcome = await stack.router.handle(
      rawUpdate: textUpdate(id: 2, from: stack.chatId, text: "/stop")
    )
    let afterStopOutcome = await stack.router.handle(
      rawUpdate: textUpdate(id: 3, from: stack.chatId, text: "after stop")
    )
    await stack.provider.waitForRequestCount(2)
    await waitForOutboxPoke(stack.signal)

    // then
    #expect(firstOutcome == .processed)
    #expect(stopOutcome == .processed)
    #expect(afterStopOutcome == .processed)
    #expect(
      try runStates(queue) == [
        RunState.cancelled.rawValue,
        RunState.done.rawValue,
      ]
    )
    #expect(await stack.transport.sent.contains { $0.text == CommandReplies.stopped })
    #expect(try stack.outbox.pendingOutbound().map(\.payload) == ["fresh reply"])
  }

  @Test func newSupersedesRunningAndQueuedRunsAndClearsContextWindow() async throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrate(queue)
    let stack = try makeStopNewStack(writer: queue)

    // when
    let firstOutcome = await stack.router.handle(
      rawUpdate: textUpdate(id: 1, from: stack.chatId, text: "before one")
    )
    await stack.provider.waitForRequestCount(1)
    let secondOutcome = await stack.router.handle(
      rawUpdate: textUpdate(id: 2, from: stack.chatId, text: "before two")
    )
    let newOutcome = await stack.router.handle(
      rawUpdate: textUpdate(id: 3, from: stack.chatId, text: "/new")
    )
    let afterNewOutcome = await stack.router.handle(
      rawUpdate: textUpdate(id: 4, from: stack.chatId, text: "after new")
    )
    await stack.provider.waitForRequestCount(2)
    await waitForOutboxPoke(stack.signal)

    // then
    #expect(firstOutcome == .processed)
    #expect(secondOutcome == .processed)
    #expect(newOutcome == .processed)
    #expect(afterNewOutcome == .processed)
    #expect(
      try runStates(queue) == [
        RunState.superseded.rawValue,
        RunState.superseded.rawValue,
        RunState.done.rawValue,
      ]
    )
    #expect(await stack.transport.sent.contains { $0.text == CommandReplies.freshConversation })

    let requests = await stack.provider.requests
    #expect(requests.count == 2)
    let secondRequestContent = requests[1].map(\.content)
    #expect(secondRequestContent.contains("after new"))
    #expect(secondRequestContent.contains("before one") == false)
    #expect(secondRequestContent.contains("before two") == false)
    #expect(try stack.outbox.pendingOutbound().map(\.payload) == ["fresh reply"])
  }
}
// swiftlint:enable function_body_length
