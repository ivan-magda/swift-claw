import ClawAgent
import ClawCore
import Foundation

// MARK: - Turn Commit

extension TurnRunner {
  /// Identifiers plus the single commit-time clock, threaded through the per-result commit helpers
  /// so every write in one turn's commit shares the same timestamp.
  struct CommitContext {
    let runID: Int64
    let sessionID: Int64
    let chatID: Int64
    let mode: ChatMode
    let ownerNotices: [String]
    let origin: RunOrigin
    let committedAt: Date
  }

  /// Persists one `TurnResult` against a single commit-time clock. The ordering is the contract:
  ///  - `.completed`: `runs.commitAssistantTurn` writes the assistant message + run→DONE +
  ///    provider_usage + outbox chunk(s) in ONE transaction, before any send; then audit + notify.
  ///  - `.degraded`: debit real usage when the call produced any (truncation / exhausted retries),
  ///    then run the shared failure tail with the kind's reply.
  ///  - `.budgetStopped`: the shared failure tail with the budget reply.
  /// Only `StoreError.diskFull` may propagate; every other failure is handled in-band here.
  func commit(  // swiftlint:disable:this function_parameter_count
    _ outcome: TurnOutcome,
    runID: Int64,
    sessionID: Int64,
    chatID: Int64,
    mode: ChatMode,
    ownerNotices: [String],
    origin: RunOrigin
  ) async throws {
    let context = CommitContext(
      runID: runID,
      sessionID: sessionID,
      chatID: chatID,
      mode: mode,
      ownerNotices: ownerNotices,
      origin: origin,
      committedAt: now()
    )

    switch outcome.result {
    case .completed(let content, let usage, let providerState):
      try await commitCompleted(
        content: content,
        usage: usage,
        providerState: providerState,
        outcome: outcome,
        in: context
      )
    case .degraded(let degradationKind, let usage):
      try await commitDegraded(kind: degradationKind, usage: usage, outcome: outcome, in: context)
    case .budgetStopped(let cap):
      try await commitBudgetStopped(cap: cap, outcome: outcome, in: context)
    case .suspended(let pending, let usage):
      try await suspendForApproval(pending: pending, usage: usage, outcome: outcome, in: context)
    }
  }

  /// The "the turn could not even assemble" fallback: a degradation commit with no usage and no
  /// exchanges, carrying the canned context-unavailable reply.
  func commitContextUnavailable(
    runID: Int64,
    sessionID: Int64,
    chatID: Int64,
    setTainted: Bool,
    at committedAt: Date
  ) throws {
    _ = try commitDegradation(
      runID: runID,
      sessionID: sessionID,
      chatID: chatID,
      usage: nil,
      exchanges: [],
      setTainted: setTainted,
      // No turn ran on this path, so no private-data leg is known.
      setPrivateData: false,
      message: ownerVisiblePayload(reply: Degradation.contextUnavailable, ownerNotices: []),
      action: .turnDegraded,
      decision: DegradationKind.contextUnavailable.auditDecision,
      cause: DegradationKind.contextUnavailable.terminalCause,
      at: committedAt
    )
  }
}

// MARK: - Terminal Outcomes

private extension TurnRunner {
  func commitCompleted(
    content: String,
    usage: ProviderUsage,
    providerState: ProviderExchangeState?,
    outcome: TurnOutcome,
    in context: CommitContext
  ) async throws {
    let appendedNotices =
      outcome.routeNotice.map {
        [Degradation.message(for: $0)]
      } ?? []
    // Ack suppression: a heartbeat ack commits with ZERO outbox chunks — the "no
    // delivery" decision is durable in the SAME store transaction as the run's DONE flip.
    let suppressHeartbeatAck = context.origin == .heartbeat && HeartbeatAck.isAck(content)
    let feedbackTarget =
      suppressHeartbeatAck
      ? nil
      : resultFeedbackTarget(runID: context.runID, chatID: context.chatID, origin: context.origin)
    let chunks =
      suppressHeartbeatAck
      ? []
      : outboxChunks(
        for: ownerVisiblePayload(
          reply: content,
          ownerNotices: context.ownerNotices,
          appendedNotices: appendedNotices
        ),
        chatID: context.chatID,
        finalReplyMarkup: feedbackTarget.map(LearningNotices.resultKeyboard)
      )
    let turn = AssistantTurn(
      runID: context.runID,
      sessionID: context.sessionID,
      chatID: context.chatID,
      content: content,
      usage: usage,
      chunks: chunks,
      exchanges: outcome.exchanges,
      setTainted: outcome.ingestedUntrusted,
      setPrivateData: outcome.hadPrivateData,
      providerState: providerState,
      feedbackTarget: feedbackTarget
    )

    switch try runs.commitAssistantTurn(turn, now: context.committedAt) {
    case .committed:
      try auditCompleted(content: content, suppressedAck: suppressHeartbeatAck, in: context)
      notifyOutbox()
      await notifyDailyCapIfTripped(in: context)
    case .usageRecordedAfterTerminal:
      await notifyDailyCapIfTripped(in: context)
    case .ignored:
      return
    }
  }

  /// Best-effort pre-resolution. The store repeats these predicates in the terminal transaction,
  /// which closes races without making owner delivery depend on learning availability.
  func resultFeedbackTarget(runID: Int64, chatID: Int64, origin: RunOrigin) -> NewFeedbackTarget? {
    guard origin == .scheduled, let learning else {
      return nil
    }
    guard let binding = try? learning.binding(runID: runID) else {
      return nil
    }
    guard (try? runs.jobID(runID: runID)) == binding.jobID else {
      return nil
    }
    guard (try? learning.lessonSet(jobID: binding.jobID, digest: binding.effectiveDigest)) != nil
    else {
      return nil
    }
    return NewFeedbackTarget(
      nonce: makeFeedbackNonce(),
      jobID: binding.jobID,
      epoch: binding.epoch,
      subjectKind: .run,
      subjectDigest: String(runID),
      allowedActions: [.resultUseful, .resultNotUseful, .resultCorrection],
      ownerUserID: chatID,
      chatID: chatID,
      expiresAt: binding.occurrenceAt.addingTimeInterval(EvidenceWindow.maximumAge)
    )
  }

  /// Audit tail for a committed `.completed` turn: the turn row, plus the heartbeat
  /// delivered/suppressed marker when the run is a heartbeat.
  func auditCompleted(content: String, suppressedAck: Bool, in context: CommitContext) throws {
    try audit.appendAudit(
      turnAudit(
        action: .turnCompleted,
        runID: context.runID,
        sessionID: context.sessionID,
        resultSize: content.utf8.count,
        at: context.committedAt
      )
    )
    guard context.origin == .heartbeat else {
      return
    }
    try audit.appendAudit(
      AuditEvent(
        actor: .assistant,
        action: suppressedAck ? .heartbeatSuppressed : .heartbeatFired,
        resultSize: content.utf8.count,
        decision: suppressedAck ? "ack" : "delivered",
        runID: context.runID,
        sessionID: context.sessionID,
        ts: context.committedAt
      )
    )
  }

  /// Executed exchanges persist even on the failure path so the next turn's context knows what
  /// already ran; the taint from any ingesting call persists with them. No approval is parked —
  /// the model's explanation never reached the owner, so the gate re-trips next time.
  func commitDegraded(
    kind: DegradationKind,
    usage: ProviderUsage?,
    outcome: TurnOutcome,
    in context: CommitContext
  ) async throws {
    // Only a switch-then-fail owes this sentence — `.restored` means the fallback was never tried.
    var appendedNotices: [String] = []
    if case .switched = outcome.routeNotice {
      appendedNotices = [Degradation.fallbackAlsoFailed]
    }
    let commitResult = try commitDegradation(
      runID: context.runID,
      sessionID: context.sessionID,
      chatID: context.chatID,
      usage: usage,
      exchanges: outcome.exchanges,
      setTainted: outcome.ingestedUntrusted,
      setPrivateData: outcome.hadPrivateData,
      message: ownerVisiblePayload(
        reply: Degradation.message(for: kind),
        ownerNotices: context.ownerNotices,
        appendedNotices: appendedNotices
      ),
      action: .turnDegraded,
      decision: kind.auditDecision,
      cause: kind.terminalCause,
      at: context.committedAt
    )
    if commitResult != .ignored {
      await notifyDailyCapIfTripped(in: context)
    }
  }

  func commitBudgetStopped(
    cap: String,
    outcome: TurnOutcome,
    in context: CommitContext
  ) async throws {
    // `routeNotice` is turn-scoped (set once, before the cap tripped), so a switch earlier in this
    // same turn still owes the owner its notice even though this round produced no answer.
    let appendedNotices =
      outcome.routeNotice.map {
        [Degradation.message(for: $0)]
      } ?? []
    _ = try commitDegradation(
      runID: context.runID,
      sessionID: context.sessionID,
      chatID: context.chatID,
      usage: nil,
      exchanges: outcome.exchanges,
      setTainted: outcome.ingestedUntrusted,
      setPrivateData: outcome.hadPrivateData,
      message: ownerVisiblePayload(
        reply: Degradation.budget(cap: cap),
        ownerNotices: context.ownerNotices,
        appendedNotices: appendedNotices
      ),
      action: .turnBudgetStopped,
      decision: cap,
      cause: .budgetStopped,
      at: context.committedAt
    )
    if context.origin != .interactive, cap == BudgetGate.proactivePerDayCap {
      await notifyProactiveCapIfTripped(in: context)
    }
  }

  /// The shared failure tail. The store owns the run-state arbitration and writes usage, FAILED,
  /// and the degradation outbox row in one transaction so `/stop`/`/new` cannot interleave.
  func commitDegradation(  // swiftlint:disable:this function_parameter_count
    runID: Int64,
    sessionID: Int64,
    chatID: Int64,
    usage: ProviderUsage?,
    exchanges: [ToolExchange],
    setTainted: Bool,
    setPrivateData: Bool,
    message: String,
    action: AuditAction,
    decision: String,
    cause: TerminalCause,
    at committedAt: Date
  ) throws -> RunCommitResult {
    let chunk = OutboxChunk(
      stepIndex: 0,
      chatID: chatID,
      payload: message,
      payloadHash: ContentHash.fnv1a(message)
    )

    let commitResult = try runs.commitDegradedTurn(
      DegradedTurn(
        runID: runID,
        sessionID: sessionID,
        chatID: chatID,
        usage: usage,
        chunk: chunk,
        exchanges: exchanges,
        setTainted: setTainted,
        setPrivateData: setPrivateData,
        cause: cause
      ),
      now: committedAt
    )
    guard commitResult == .committed else {
      return commitResult
    }

    try audit.appendAudit(
      turnAudit(
        action: action,
        runID: runID,
        sessionID: sessionID,
        decision: decision,
        at: committedAt
      )
    )
    notifyOutbox()

    return commitResult
  }
}

// MARK: - Budget Notifications

private extension TurnRunner {
  /// Post-commit daily kill-switch. Reads today's totals (durable, from `provider_usage`) and asks
  /// the breaker whether to DM the owner — `shouldNotifyTrip` is idempotent per UTC day, so calling
  /// this from both the `.completed` and `.degraded` branches still yields at most one DM. The DM and
  /// its audit are best-effort (`try?`): a failed send is acceptable, unlike a failed refusal.
  func notifyDailyCapIfTripped(in context: CommitContext) async {
    guard let breaker, let delivery else {
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

    if let target = ownerNoticeTarget(for: context) {
      _ = try? await delivery.sendMessage(chatID: target, text: Degradation.dailyCapTripped)
    }
    try? audit.appendAudit(
      AuditEvent(
        actor: .system,
        action: .budgetTripped,
        decision: "daily_cap",
        runID: context.runID,
        sessionID: context.sessionID,
        ts: Date()
      )
    )
  }

  /// Post-commit proactive-cap owner DM: once per UTC day via the breaker's second latch.
  /// The trip itself is already durable (the run FAILED with the cap named); DM + audit are
  /// best-effort, mirroring `notifyDailyCapIfTripped`.
  func notifyProactiveCapIfTripped(in context: CommitContext) async {
    guard let breaker, let delivery else {
      return
    }

    let shouldNotify = await breaker.shouldNotifyProactiveTrip(now: Date())
    guard shouldNotify else {
      return
    }

    if let target = ownerNoticeTarget(for: context) {
      _ = try? await delivery.sendMessage(chatID: target, text: Degradation.proactiveCapTripped)
    }
    try? audit.appendAudit(
      AuditEvent(
        actor: .system,
        action: .budgetTripped,
        decision: "proactive_per_day",
        runID: context.runID,
        sessionID: context.sessionID,
        ts: Date()
      )
    )
  }

  func ownerNoticeTarget(for context: CommitContext) -> Int64? {
    context.mode == .group ? ownerChatID : context.chatID
  }
}
