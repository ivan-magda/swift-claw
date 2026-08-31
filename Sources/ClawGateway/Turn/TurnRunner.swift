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
  /// Continues a run the approval waiter already flipped AWAITING_APPROVAL → RUNNING: no pick-up,
  /// context bound to the filled observation row, budget counters carried over.
  func resume(runId: Int64, sessionId: Int64, chatId: Int64, contextBoundMessageId: Int64) async
}

extension TurnDispatching {
  public func resume(
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    contextBoundMessageId: Int64
  ) async {}
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
  package let imageCache: ImageCache
  /// Pokes the outbox dispatcher to drain after a commit. A no-op until the dispatcher is wired.
  private let notifyOutbox: @Sendable () -> Void
  /// Post-commit daily kill-switch and its best-effort owner-DM delivery port.
  private let breaker: BudgetBreaker?
  private let delivery: (any MessageDelivery)?
  /// The config-resolved owner DM for process-wide notices raised by a group turn.
  private let ownerChatId: Int64?
  /// The turn's clock. Sourcing the budget "today" window from an injected now (defaulting to the
  /// real clock) keeps the proactive/global daily-spend boundary deterministic under test — the
  /// same seam ContextBuilder/MessageRouter/SchedulerService already use.
  private let now: @Sendable () -> Date

  private let logger: Logger

  /// The lane-hold seam: after the suspend commit, `park` awaits the durable approval's
  /// resolution.
  private let parker: any ApprovalParking
  /// Seconds a suspended approval stays live (ARCHITECTURE.md §11). Injected so the commit's
  /// `expires_ts` is deterministic under test.
  private let approvalExpirySeconds: Int

  /// Most-recent messages pulled for context; `ContextBuilder` then caps by grapheme budget.
  private static let historyLimit = 50

  package init(
    sessionMessages: any SessionMessageStore,
    runs: any RunStore,
    usageStore: any UsageStore,
    audit: any AuditLog,
    agent: AgentRuntime,
    budget: RunBudget,
    contextBuilder: ContextBuilder,
    imageCache: ImageCache,
    notifyOutbox: @escaping @Sendable () -> Void,
    breaker: BudgetBreaker? = nil,
    delivery: (any MessageDelivery)? = nil,
    ownerChatId: Int64? = nil,
    now: @escaping @Sendable () -> Date = { Date() },
    // No default: an ask-tier suspend parks the lane on this seam, and a composition site that
    // silently fell back to an inert parker (whose private coordinator no resolver ever signals)
    // would hold that lane forever. Every caller chooses its parker explicitly.
    parker: any ApprovalParking,
    approvalExpirySeconds: Int,
    logger: Logger
  ) {
    self.sessionMessages = sessionMessages
    self.runs = runs
    self.usageStore = usageStore

    self.audit = audit
    self.agent = agent
    self.budget = budget
    self.contextBuilder = contextBuilder
    self.imageCache = imageCache

    self.notifyOutbox = notifyOutbox
    self.breaker = breaker
    self.delivery = delivery
    self.ownerChatId = ownerChatId

    self.now = now
    self.parker = parker
    self.approvalExpirySeconds = approvalExpirySeconds
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

    let now = now()
    // The fingerprint is computed from the same builder inputs `assemble` will use and
    // stamped in the same UPDATE that flips PENDING→RUNNING, so an approval this run creates binds
    // to the exact prompt/tool/config surface in force at run start.
    let policyVersion = contextBuilder.currentPolicyVersion()
    guard let origin = try runs.pickUp(runId: runId, policyVersion: policyVersion, now: now) else {
      logger.debug("run \(runId) was not pending at pickup; skipping turn")
      return
    }

    guard !Task.isCancelled else {
      return
    }

    let inputs: TurnInputs
    do {
      inputs = try loadTurnInputs(
        sessionId: sessionId,
        boundMessageId: triggerMessageId,
        origin: origin,
        at: now,
        images: await cachedImages(sessionId: sessionId)
      )
    } catch StoreError.diskFull {
      throw StoreError.diskFull
    } catch {
      logger.error("context build failed for run \(runId): \(error)")
      try commitContextUnavailable(
        runId: runId,
        sessionId: sessionId,
        chatId: chatId,
        setTainted: false,
        at: Date()
      )
      return
    }

    // Real session taint: the gate reads `(session ∪ run)`, so a session already tainted by a
    // prior turn keeps the exfil gate armed from this run's very first tool call.
    let mode = SessionKey.mode(from: inputs.snapshot.sessionKey)
    let outcome = try await agent.runTurn(
      runId: runId,
      sessionId: sessionId,
      chatId: chatId,
      buildResult: inputs.buildResult,
      sessionTainted: inputs.snapshot.isTainted,
      sessionHasPrivateData: inputs.snapshot.hasPrivateData,
      autoApproveWindowOpen: autoApproveWindowOpen(runId: runId),
      todayTokens: inputs.todayTokens,
      todayUSD: inputs.todayUSD,
      origin: origin,
      proactiveTodayUSD: inputs.proactiveTodayUSD,
      mode: mode,
      threadId: SessionKey.threadId(from: inputs.snapshot.sessionKey)
    )

    try await commit(
      outcome,
      runId: runId,
      sessionId: sessionId,
      chatId: chatId,
      mode: mode,
      ownerNotices: inputs.buildResult.ownerNotices,
      origin: origin
    )
  }

  /// The post-approval continuation, identical to `run` except: no `pickUp` (the waiter already
  /// flipped AWAITING_APPROVAL → RUNNING via the executor), the context bound is the FILLED
  /// observation row's message id (the trigger id would exclude the partial exchange), and
  /// `runTurn` is seeded
  /// with the run's carried-over budget counters. Non-throwing: it runs on the session lane inside
  /// the waiter's `park`, so every failure resolves in-band (a build/turn failure fails the run so
  /// the lane frees).
  public func resume(
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    contextBoundMessageId: Int64
  ) async {
    guard !Task.isCancelled else {
      return
    }

    guard let origin = resumeOrigin(runId: runId) else {
      return
    }

    let inputs: TurnInputs
    let carryOver: ResumeUsage
    do {
      carryOver = try runs.resumeUsage(runId: runId)
      inputs = try loadTurnInputs(
        sessionId: sessionId,
        boundMessageId: contextBoundMessageId,
        origin: origin,
        at: now(),
        images: await cachedImages(sessionId: sessionId)
      )
    } catch {
      failResume(runId: runId, stage: "context build", error: error)
      return
    }

    let mode = SessionKey.mode(from: inputs.snapshot.sessionKey)
    let outcome: TurnOutcome
    do {
      outcome = try await agent.runTurn(
        runId: runId,
        sessionId: sessionId,
        chatId: chatId,
        buildResult: inputs.buildResult,
        sessionTainted: inputs.snapshot.isTainted,
        sessionHasPrivateData: inputs.snapshot.hasPrivateData,
        autoApproveWindowOpen: autoApproveWindowOpen(runId: runId),
        todayTokens: inputs.todayTokens,
        todayUSD: inputs.todayUSD,
        origin: origin,
        proactiveTodayUSD: inputs.proactiveTodayUSD,
        carryOver: carryOver,
        mode: mode,
        threadId: SessionKey.threadId(from: inputs.snapshot.sessionKey)
      )
    } catch {
      failResume(runId: runId, stage: "turn", error: error)
      return
    }

    do {
      try await commit(
        outcome,
        runId: runId,
        sessionId: sessionId,
        chatId: chatId,
        mode: mode,
        ownerNotices: inputs.buildResult.ownerNotices,
        origin: origin
      )
    } catch {
      logger.error("resume commit failed for run \(runId): \(error)")
    }
  }
}

// MARK: - Per-Run Turn Inputs

private extension TurnRunner {
  /// The run's origin, read without a re-pick-up. The prompt wording, the budget pool, and the
  /// gate's owner-present check all key on it, so a missing or unreadable origin ends the resume
  /// rather than guessing — a resume runs inside the waiter's `park`, so both resolve in-band.
  func resumeOrigin(runId: Int64) -> RunOrigin? {
    do {
      guard let origin = try runs.runOrigin(runId: runId) else {
        logger.debug("run \(runId) has no origin at resume; skipping")
        return nil
      }
      return origin
    } catch {
      logger.error("resume origin read failed for run \(runId): \(error)")
      return nil
    }
  }

  /// Reads the run's turn-scoped window for the gate. Both entry points ask, so the widening is a
  /// property of the run rather than of how the turn started; a read that fails reports closed,
  /// which costs the owner one more prompt and never one fewer.
  func autoApproveWindowOpen(runId: Int64) -> Bool {
    do {
      return try runs.isAutoApproveWindowOpen(runId: runId)
    } catch {
      logger.error("auto-approve window read failed for run \(runId): \(error)")
      return false
    }
  }
}

// MARK: - Context Assembly

private extension TurnRunner {
  /// Loads the bounded snapshot, today's budget totals, and the assembled context in one place —
  /// `run` and `resume` share it; only the bounding message id and the clock differ.
  func loadTurnInputs(
    sessionId: Int64,
    boundMessageId: Int64,
    origin: RunOrigin,
    at clock: Date,
    images: [Int64: ImagePart]
  ) throws -> TurnInputs {
    let loaded = try sessionMessages.loadContextSnapshot(
      sessionId: sessionId,
      throughMessageId: boundMessageId,
      limit: Self.historyLimit
    )
    let snapshot = Self.attach(images, to: loaded)
    let totals = try usageStore.todayTokensAndCost(now: clock)
    // The proactive pool is one aggregate over scheduled + heartbeat; interactive runs never
    // pay for the extra query.
    let proactiveTodayUSD: Double
    if origin == .interactive {
      proactiveTodayUSD = 0
    } else {
      proactiveTodayUSD =
        try usageStore.todayTokensAndCost(origins: [.scheduled, .heartbeat], now: clock).costUSD
    }
    let buildResult = try contextBuilder.assemble(
      snapshot: snapshot,
      sessionId: sessionId,
      origin: origin
    )
    return TurnInputs(
      snapshot: snapshot,
      buildResult: buildResult,
      todayTokens: totals.tokens,
      todayUSD: totals.costUSD,
      proactiveTodayUSD: proactiveTodayUSD
    )
  }

  /// `resume`'s shared failure tail: every pre-commit failure fails the run in-band (best-effort)
  /// so the lane frees — `resume` is non-throwing by contract.
  func failResume(runId: Int64, stage: String, error: any Error) {
    logger.error("resume \(stage) failed for run \(runId): \(error)")
    try? runs.failRun(runId: runId, now: now())
  }
}

// MARK: - Turn Commit

/// Not `private`: the outcome-mapping gateway tests commit a hand-built `TurnOutcome` directly, so
/// `commit` needs to be reachable outside this file. Its helpers below stay `private` — nothing
/// else calls them.
extension TurnRunner {
  /// Persists one `TurnResult` against a single commit-time clock. The ordering is the contract:
  ///  - `.completed`: `runs.commitAssistantTurn` writes the assistant message + run→DONE +
  ///    provider_usage + outbox chunk(s) in ONE transaction, before any send; then audit + notify.
  ///  - `.degraded`: debit real usage when the call produced any (truncation / exhausted retries),
  ///    then run the shared failure tail with the kind's reply.
  ///  - `.budgetStopped`: the shared failure tail with the budget reply.
  /// Only `StoreError.diskFull` may propagate; every other failure is handled in-band here.
  func commit(  // swiftlint:disable:this function_parameter_count
    _ outcome: TurnOutcome,
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    mode: ChatMode,
    ownerNotices: [String],
    origin: RunOrigin
  ) async throws {
    let context = CommitContext(
      runId: runId,
      sessionId: sessionId,
      chatId: chatId,
      mode: mode,
      ownerNotices: ownerNotices,
      origin: origin,
      committedAt: Date()
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
}

private extension TurnRunner {
  func commitCompleted(
    content: String,
    usage: ProviderUsage,
    providerState: ProviderExchangeState?,
    outcome: TurnOutcome,
    in context: CommitContext
  ) async throws {
    let appendedNotices = outcome.routeNotice.map { [Degradation.message(for: $0)] } ?? []
    // Ack suppression: a heartbeat ack commits with ZERO outbox chunks — the "no
    // delivery" decision is durable in the SAME store transaction as the run's DONE flip.
    let suppressHeartbeatAck = context.origin == .heartbeat && HeartbeatAck.isAck(content)
    let chunks =
      suppressHeartbeatAck
      ? []
      : outboxChunks(
        for: ownerVisiblePayload(
          reply: content,
          ownerNotices: context.ownerNotices,
          appendedNotices: appendedNotices
        ),
        chatId: context.chatId
      )
    let turn = AssistantTurn(
      runId: context.runId,
      sessionId: context.sessionId,
      chatId: context.chatId,
      content: content,
      usage: usage,
      chunks: chunks,
      exchanges: outcome.exchanges,
      setTainted: outcome.ingestedUntrusted,
      setPrivateData: outcome.hadPrivateData,
      providerState: providerState
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

  /// Audit tail for a committed `.completed` turn: the turn row, plus the heartbeat
  /// delivered/suppressed marker when the run is a heartbeat.
  func auditCompleted(content: String, suppressedAck: Bool, in context: CommitContext) throws {
    try audit.appendAudit(
      turnAudit(
        action: .turnCompleted,
        runId: context.runId,
        sessionId: context.sessionId,
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
        runId: context.runId,
        sessionId: context.sessionId,
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
      runId: context.runId,
      sessionId: context.sessionId,
      chatId: context.chatId,
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
    let appendedNotices = outcome.routeNotice.map { [Degradation.message(for: $0)] } ?? []
    _ = try commitDegradation(
      runId: context.runId,
      sessionId: context.sessionId,
      chatId: context.chatId,
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
      at: context.committedAt
    )
    if context.origin != .interactive, cap == BudgetGate.proactivePerDayCap {
      await notifyProactiveCapIfTripped(in: context)
    }
  }

  /// The shared failure tail. The store owns the run-state arbitration and writes usage, FAILED,
  /// and the degradation outbox row in one transaction so `/stop`/`/new` cannot interleave.
  func commitDegradation(  // swiftlint:disable:this function_parameter_count
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    usage: ProviderUsage?,
    exchanges: [ToolExchange],
    setTainted: Bool,
    setPrivateData: Bool,
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
        exchanges: exchanges,
        setTainted: setTainted,
        setPrivateData: setPrivateData
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

  /// The "the turn could not even assemble" fallback: a degradation commit with no usage and no
  /// exchanges, carrying the canned context-unavailable reply.
  func commitContextUnavailable(
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    setTainted: Bool,
    at committedAt: Date
  ) throws {
    _ = try commitDegradation(
      runId: runId,
      sessionId: sessionId,
      chatId: chatId,
      usage: nil,
      exchanges: [],
      setTainted: setTainted,
      // No turn ran on this path, so no private-data leg is known.
      setPrivateData: false,
      message: ownerVisiblePayload(reply: Degradation.contextUnavailable, ownerNotices: []),
      action: .turnDegraded,
      decision: DegradationKind.contextUnavailable.auditDecision,
      at: committedAt
    )
  }
}

// MARK: - Suspend Commit

private extension TurnRunner {
  /// Persists the suspend checkpoint, drains the prompt, then HOLDS the lane on the durable
  /// approval.
  /// A lost-arbitration race (a /stop//new already terminated the run) or a write fault rolls the
  /// commit back — there is nothing to park, so the turn simply ends (in-band, no throw escapes).
  func suspendForApproval(
    pending: PendingToolAction,
    usage: ProviderUsage,
    outcome: TurnOutcome,
    in context: CommitContext
  ) async throws {
    // Invariant: `.suspended` is only returned after `outcome.exchanges.append(...)` upstream, so
    // `exchanges.last` is never nil on this path — this branch is defensive-only, unreachable today.
    // `usage` here is the SAME intermediate usage AgentRuntime already recorded mid-loop; passing it
    // to `commitDegradation` would debit `provider_usage` a second time for the same round. Pass
    // `nil` so this dead fallback can never double-debit even if the invariant above ever broke.
    guard let anchor = outcome.exchanges.last else {
      logger.error("suspended turn for run \(context.runId) carried no exchange; failing in-band")
      try commitContextUnavailable(
        runId: context.runId,
        sessionId: context.sessionId,
        chatId: context.chatId,
        setTainted: outcome.ingestedUntrusted,
        at: context.committedAt
      )
      return
    }

    let nonce = ApprovalNonce.generate()
    let completed =
      anchor.observations
      .filter { $0.callId != pending.toolCallId }
      .map { ToolObservationRow(toolCallId: $0.callId, content: $0.content) }

    let commit = SuspendedTurnCommit(
      assistantContent: anchor.assistantContent,
      toolCallsJSON: ToolCallCoding.encode(anchor.toolCalls) ?? "[]",
      completedObservations: completed,
      pending: pending,
      ownerUserId: context.chatId,
      nonce: nonce,
      promptChunks: approvalPromptChunks(
        pending: pending,
        outcome: outcome,
        chatId: context.chatId,
        nonce: nonce
      ),
      setTainted: outcome.ingestedUntrusted,
      setPrivateData: outcome.hadPrivateData,
      providerState: anchor.providerState,
      expiresTs: context.committedAt.addingTimeInterval(TimeInterval(approvalExpirySeconds))
    )

    let receipt: SuspendedCommitReceipt
    do {
      receipt = try runs.commitSuspendedTurn(
        runId: context.runId,
        sessionId: context.sessionId,
        commit: commit,
        now: context.committedAt
      )
    } catch StoreError.diskFull {
      throw StoreError.diskFull
    } catch {
      logger.debug("suspend commit did not apply for run \(context.runId): \(error)")
      return
    }

    notifyOutbox()
    // Holds THIS lane Task until the approval resolves; the waiter performs the resume/deny.
    await parker.park(
      approvalId: receipt.approvalId,
      runId: context.runId,
      sessionId: context.sessionId,
      chatId: context.chatId,
      revalidatePolicyOnApprove: false
    )
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
      _ = try? await delivery.sendMessage(chatId: target, text: Degradation.dailyCapTripped)
    }
    try? audit.appendAudit(
      AuditEvent(
        actor: .system,
        action: .budgetTripped,
        decision: "daily_cap",
        runId: context.runId,
        sessionId: context.sessionId,
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
      _ = try? await delivery.sendMessage(chatId: target, text: Degradation.proactiveCapTripped)
    }
    try? audit.appendAudit(
      AuditEvent(
        actor: .system,
        action: .budgetTripped,
        decision: "proactive_per_day",
        runId: context.runId,
        sessionId: context.sessionId,
        ts: Date()
      )
    )
  }

  func ownerNoticeTarget(for context: CommitContext) -> Int64? {
    context.mode == .group ? ownerChatId : context.chatId
  }
}
