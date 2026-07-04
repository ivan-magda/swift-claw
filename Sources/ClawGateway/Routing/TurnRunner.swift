import ClawAgent
import ClawCore
import Foundation
import Logging

/// Injected behind a protocol so the router/poller tests stay decoupled from the real provider.
public protocol TurnDispatching: Sendable {
  func run(
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    triggerMessageId: Int64
  ) async throws
}

/// Picks up a durable PENDING run, assembles its trigger-bounded context, executes the agent, and
/// persists the outcome.
public struct TurnRunner: TurnDispatching {
  private let sessionMessages: any SessionMessageStore
  private let runs: any RunStore
  private let usageStore: any UsageStore
  private let audit: any AuditLog
  private let agent: AgentRuntime
  private let budget: RunBudget
  private let contextBuilder: ContextBuilder
  /// Pokes the outbox dispatcher to drain after a commit. A no-op until Task 6 wires the dispatcher.
  private let notifyOutbox: @Sendable () -> Void
  /// Post-commit daily kill-switch + the transport for its owner DM. Both `nil` in tests that don't
  /// exercise the breaker (the DM is best-effort and out-of-band from the durable outbox, D4).
  private let breaker: BudgetBreaker?
  private let transport: (any TelegramTransport)?
  private let logger: Logger

  /// Most-recent messages pulled for context; `ContextBuilder` then caps by grapheme budget (§9).
  private static let historyLimit = 50

  public init(
    sessionMessages: any SessionMessageStore,
    runs: any RunStore,
    usageStore: any UsageStore,
    audit: any AuditLog,
    agent: AgentRuntime,
    budget: RunBudget,
    contextBuilder: ContextBuilder,
    notifyOutbox: @escaping @Sendable () -> Void,
    breaker: BudgetBreaker? = nil,
    transport: (any TelegramTransport)? = nil,
    logger: Logger
  ) {
    self.sessionMessages = sessionMessages
    self.runs = runs
    self.usageStore = usageStore
    self.audit = audit
    self.agent = agent
    self.budget = budget
    self.contextBuilder = contextBuilder
    self.notifyOutbox = notifyOutbox
    self.breaker = breaker
    self.transport = transport
    self.logger = logger
  }

  public func run(
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    triggerMessageId: Int64
  ) async throws {
    guard !Task.isCancelled else {
      return
    }

    let now = Date()
    guard try runs.pickUp(runId: runId, now: now) else {
      logger.debug("run \(runId) was not pending at pickup; skipping turn")
      return
    }

    guard !Task.isCancelled else {
      return
    }

    let buildResult: BuildResult
    let todayTokens: Int
    let todayUSD: Double

    do {
      let snapshot = try sessionMessages.loadContextSnapshot(
        sessionId: sessionId,
        throughMessageId: triggerMessageId,
        limit: Self.historyLimit
      )

      let totals = try usageStore.todayTokensAndCost(now: now)
      todayTokens = totals.tokens
      todayUSD = totals.costUSD

      buildResult = try contextBuilder.assemble(snapshot: snapshot, sessionId: sessionId)
    } catch StoreError.diskFull {
      throw StoreError.diskFull
    } catch {
      logger.error("context build failed for run \(runId): \(error)")
      _ = try commitDegradation(
        runId: runId,
        sessionId: sessionId,
        chatId: chatId,
        usage: nil,
        message: ownerVisiblePayload(
          reply: Degradation.contextUnavailable,
          ownerNotices: []
        ),
        action: .turnDegraded,
        decision: DegradationKind.contextUnavailable.rawValue,
        at: Date()
      )
      return
    }

    // sessionTainted/fetchGrant plumbing lands in Task 24; the loop's tool dispatch is a no-op
    // (toolDispatcher: nil, wired in Task 25) so these placeholders don't change today's behavior.
    let outcome = try await agent.runTurn(
      runId: runId,
      sessionId: sessionId,
      chatId: chatId,
      buildResult: buildResult,
      sessionTainted: false,
      fetchGrant: nil,
      todayTokens: todayTokens,
      todayUSD: todayUSD
    )

    try await commit(
      outcome.result,
      runId: runId,
      sessionId: sessionId,
      chatId: chatId,
      ownerNotices: buildResult.ownerNotices
    )
  }

  // MARK: - Load-bearing

  /// Persists one `TurnResult` against a single commit-time clock. The ordering is the contract:
  ///  - `.completed`: `runs.commitAssistantTurn` writes the assistant message + run→DONE +
  ///    provider_usage + outbox chunk(s) in ONE transaction, before any send; then audit + notify.
  ///  - `.degraded`: debit real usage when the call produced any (truncation / exhausted retries),
  ///    then run the shared failure tail with the kind's reply.
  ///  - `.budgetStopped`: the shared failure tail with the budget reply.
  /// Only `StoreError.diskFull` may propagate; every other failure is handled in-band here.
  private func commit(
    _ result: TurnResult,
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    ownerNotices: [String]
  ) async throws {
    let committedAt = Date()

    switch result {
    case .completed(let content, let usage):
      let turn = AssistantTurn(
        runId: runId,
        sessionId: sessionId,
        chatId: chatId,
        content: content,
        usage: usage,
        chunks: outboxChunks(
          for: ownerVisiblePayload(reply: content, ownerNotices: ownerNotices),
          chatId: chatId
        )
      )

      let commitResult = try runs.commitAssistantTurn(turn, now: committedAt)
      switch commitResult {
      case .committed:
        try audit.appendAudit(
          turnAudit(
            action: .turnCompleted,
            runId: runId,
            sessionId: sessionId,
            resultSize: content.utf8.count,
            at: committedAt
          )
        )
        notifyOutbox()
        await notifyDailyCapIfTripped(chatId: chatId, runId: runId, sessionId: sessionId)
      case .usageRecordedAfterTerminal:
        await notifyDailyCapIfTripped(chatId: chatId, runId: runId, sessionId: sessionId)
      case .ignored:
        return
      }
    case .degraded(let degradationKind, let usage):
      let commitResult = try commitDegradation(
        runId: runId,
        sessionId: sessionId,
        chatId: chatId,
        usage: usage,
        message: ownerVisiblePayload(
          reply: Degradation.message(for: degradationKind),
          ownerNotices: ownerNotices
        ),
        action: .turnDegraded,
        decision: degradationKind.rawValue,
        at: committedAt
      )
      if commitResult != .ignored {
        await notifyDailyCapIfTripped(chatId: chatId, runId: runId, sessionId: sessionId)
      }
    case .budgetStopped(let cap):
      _ = try commitDegradation(
        runId: runId,
        sessionId: sessionId,
        chatId: chatId,
        usage: nil,
        message: ownerVisiblePayload(
          reply: Degradation.budget(cap: cap),
          ownerNotices: ownerNotices
        ),
        action: .turnBudgetStopped,
        decision: cap,
        at: committedAt
      )
    }
  }

  /// The shared failure tail. The store owns the run-state arbitration and writes usage, FAILED,
  /// and the degradation outbox row in one transaction so `/stop`/`/new` cannot interleave.
  private func commitDegradation(  // swiftlint:disable:this function_parameter_count
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    usage: ProviderUsage?,
    message: String,
    action: AuditAction,
    decision: String,
    at committedAt: Date
  ) throws -> RunCommitResult {
    let chunk = OutboxChunk(
      stepIndex: 0,
      chatId: chatId,
      payload: message,
      payloadHash: ContentHash.fnv1a(message)
    )

    let commitResult = try runs.commitDegradedTurn(
      DegradedTurn(
        runId: runId,
        sessionId: sessionId,
        chatId: chatId,
        usage: usage,
        chunk: chunk
      ),
      now: committedAt
    )
    guard commitResult == .committed else {
      return commitResult
    }

    try audit.appendAudit(
      turnAudit(
        action: action,
        runId: runId,
        sessionId: sessionId,
        decision: decision,
        at: committedAt
      )
    )
    notifyOutbox()

    return commitResult
  }

  /// Post-commit daily kill-switch. Reads today's totals (durable, from `provider_usage`) and asks
  /// the breaker whether to DM the owner — `shouldNotifyTrip` is idempotent per UTC day, so calling
  /// this from both the `.completed` and `.degraded` branches still yields at most one DM. The DM and
  /// its audit are best-effort (`try?`): a failed send is acceptable (D4), unlike a failed refusal.
  private func notifyDailyCapIfTripped(
    chatId: Int64,
    runId: Int64,
    sessionId: Int64
  ) async {
    guard let breaker, let transport else {
      return
    }

    let now = Date()
    guard let totals = try? usageStore.todayTokensAndCost(now: now) else {
      return
    }

    let shouldNotify = await breaker.shouldNotifyTrip(
      todayTokens: totals.tokens,
      todayUSD: totals.costUSD,
      now: now
    )
    guard shouldNotify else {
      return
    }

    _ = try? await transport.sendMessage(chatId: chatId, text: Degradation.dailyCapTripped)
    try? audit.appendAudit(
      AuditEvent(
        actor: .system,
        action: .budgetTripped,
        decision: "daily_cap",
        runId: runId,
        sessionId: sessionId,
        ts: Date()
      )
    )
  }

  /// Builds the audit row for a finished turn (actor = assistant, the turn's author).
  private func turnAudit(
    action: AuditAction,
    runId: Int64,
    sessionId: Int64,
    resultSize: Int = 0,
    decision: String = "ok",
    at ts: Date
  ) -> AuditEvent {
    AuditEvent(
      actor: .assistant,
      action: action,
      resultSize: resultSize,
      decision: decision,
      runId: runId,
      sessionId: sessionId,
      ts: ts
    )
  }

  private func ownerVisiblePayload(reply: String, ownerNotices: [String]) -> String {
    guard ownerNotices.isEmpty == false else {
      return reply
    }
    return (ownerNotices + [reply]).joined(separator: "\n\n")
  }

  /// Splits an assistant reply into deterministic outbox chunks (grapheme-capped, FNV-1a hashed).
  /// Mechanical helper for the `.completed` path — not part of the commit ordering.
  private func outboxChunks(for content: String, chatId: Int64) -> [OutboxChunk] {
    ReplySplitter.split(text: content).enumerated().map { index, payload in
      OutboxChunk(
        stepIndex: index,
        chatId: chatId,
        payload: payload,
        payloadHash: ContentHash.fnv1a(payload)
      )
    }
  }
}
