import ClawAgent
import ClawCore
import Foundation
import Logging

/// Injected behind a protocol so the router/poller tests stay decoupled from the real provider.
public protocol TurnDispatching: Sendable {
  // swiftlint:disable:next function_parameter_count
  func run(
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    triggerMessageId: Int64,
    grant: OneTurnGrant?
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
  /// One approval slot per session; a `.completed` run that tripped an approval gate parks its
  /// request here (only after its commit wins arbitration) so a later `yes` can arm the grant.
  private let pendingConfirmations: PendingConfirmationRegistry
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
    pendingConfirmations: PendingConfirmationRegistry,
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
    self.pendingConfirmations = pendingConfirmations
    self.notifyOutbox = notifyOutbox
    self.breaker = breaker
    self.transport = transport
    self.logger = logger
  }

  public func run(
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    triggerMessageId: Int64,
    grant: OneTurnGrant?
  ) async throws {
    guard !Task.isCancelled else {
      return
    }

    let now = Date()
    guard let origin = try runs.pickUp(runId: runId, now: now) else {
      logger.debug("run \(runId) was not pending at pickup; skipping turn")
      return
    }

    guard !Task.isCancelled else {
      return
    }

    let snapshot: SessionContextSnapshot
    let buildResult: BuildResult
    let todayTokens: Int
    let todayUSD: Double
    let proactiveTodayUSD: Double

    do {
      snapshot = try sessionMessages.loadContextSnapshot(
        sessionId: sessionId,
        throughMessageId: triggerMessageId,
        limit: Self.historyLimit
      )

      let totals = try usageStore.todayTokensAndCost(now: now)
      todayTokens = totals.tokens
      todayUSD = totals.costUSD
      // The proactive pool is one aggregate over scheduled + heartbeat (spec §11); interactive
      // runs never pay for the extra query.
      if origin == .interactive {
        proactiveTodayUSD = 0
      } else {
        proactiveTodayUSD =
          try usageStore.todayTokensAndCost(origins: [.scheduled, .heartbeat], now: now).costUSD
      }

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
        setTainted: false,
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

    // Real session taint (§10): the gate reads `(session ∪ run)`, so a session already tainted by a
    // prior turn keeps the exfil gate armed from this run's very first tool call.
    let outcome = try await agent.runTurn(
      runId: runId,
      sessionId: sessionId,
      chatId: chatId,
      buildResult: buildResult,
      sessionTainted: snapshot.isTainted,
      grant: grant,
      todayTokens: todayTokens,
      todayUSD: todayUSD,
      origin: origin,
      proactiveTodayUSD: proactiveTodayUSD
    )

    try await commit(
      outcome,
      runId: runId,
      sessionId: sessionId,
      chatId: chatId,
      ownerNotices: buildResult.ownerNotices,
      origin: origin
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
  // swiftlint:disable:next function_parameter_count
  private func commit(
    _ outcome: TurnOutcome,
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    ownerNotices: [String],
    origin: RunOrigin
  ) async throws {
    let committedAt = Date()

    switch outcome.result {
    case .completed(let content, let usage):
      // The deterministic approval prompt (D7) is APPENDED after the model's reply; overflow owner
      // notices keep their PREPEND slot (rev.1 L1). Delivery-only — never stored as history.
      let appendedNotices =
        outcome.pendingApproval.map { approval in
          [ToolApprovalPrompt.text(for: approval)]
        } ?? []
      let turn = AssistantTurn(
        runId: runId,
        sessionId: sessionId,
        chatId: chatId,
        content: content,
        usage: usage,
        chunks: outboxChunks(
          for: ownerVisiblePayload(
            reply: content,
            ownerNotices: ownerNotices,
            appendedNotices: appendedNotices
          ),
          chatId: chatId
        ),
        exchanges: outcome.exchanges,
        setTainted: outcome.ingestedUntrusted
      )

      let commitResult = try runs.commitAssistantTurn(turn, now: committedAt)
      switch commitResult {
      case .committed:
        // Park ONLY after the commit won arbitration — a superseded run must not leave a live
        // approval behind. One slot per session: parking replaces (deny-by-default holds).
        if let approval = outcome.pendingApproval {
          await pendingConfirmations.park(.toolApproval(approval), sessionId: sessionId)
        }
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
      // Exchanges are lost by design on the failure path (§10); the taint from any ingesting call
      // this run still persists so the next turn's gate stays armed. No approval is parked — the
      // model's explanation never reached the owner, so the gate simply re-trips next time.
      let commitResult = try commitDegradation(
        runId: runId,
        sessionId: sessionId,
        chatId: chatId,
        usage: usage,
        setTainted: outcome.ingestedUntrusted,
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
        setTainted: outcome.ingestedUntrusted,
        message: ownerVisiblePayload(
          reply: Degradation.budget(cap: cap),
          ownerNotices: ownerNotices
        ),
        action: .turnBudgetStopped,
        decision: cap,
        at: committedAt
      )
      if origin != .interactive, cap == BudgetGate.proactivePerDayCap {
        await notifyProactiveCapIfTripped(chatId: chatId, runId: runId, sessionId: sessionId)
      }
    }
  }

  /// The shared failure tail. The store owns the run-state arbitration and writes usage, FAILED,
  /// and the degradation outbox row in one transaction so `/stop`/`/new` cannot interleave.
  private func commitDegradation(  // swiftlint:disable:this function_parameter_count
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    usage: ProviderUsage?,
    setTainted: Bool,
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
        chunk: chunk,
        setTainted: setTainted
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

  /// Post-commit proactive-cap owner DM (§11): once per UTC day via the breaker's second latch.
  /// The trip itself is already durable (the run FAILED with the cap named); DM + audit are
  /// best-effort, mirroring `notifyDailyCapIfTripped`.
  private func notifyProactiveCapIfTripped(
    chatId: Int64,
    runId: Int64,
    sessionId: Int64
  ) async {
    guard let breaker, let transport else {
      return
    }

    let shouldNotify = await breaker.shouldNotifyProactiveTrip(now: Date())
    guard shouldNotify else {
      return
    }

    _ = try? await transport.sendMessage(chatId: chatId, text: Degradation.proactiveCapTripped)
    try? audit.appendAudit(
      AuditEvent(
        actor: .system,
        action: .budgetTripped,
        decision: "proactive_per_day",
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

  /// Assembles the owner-visible payload: overflow notices PREPEND (rev.1 L1), the approval
  /// prompt APPENDS. Single-part payloads (the common case) pass through unchanged.
  private func ownerVisiblePayload(
    reply: String,
    ownerNotices: [String],
    appendedNotices: [String] = []
  ) -> String {
    let parts = ownerNotices + [reply] + appendedNotices
    guard parts.count > 1 else {
      return reply
    }
    return parts.joined(separator: "\n\n")
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
