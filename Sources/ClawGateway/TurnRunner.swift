import ClawAgent
import ClawCore
import Foundation
import Logging

/// Injected behind a protocol so the router/poller tests stay decoupled from the real provider.
public protocol TurnDispatching: Sendable {
  func run(sessionId: Int64, chatId: Int64) async throws
}

/// Orchestrates one inline turn at the gateway boundary: create the run, assemble context, hand it
/// to the agent, then persist the outcome. The agent never throws (every failure is a `TurnResult`),
/// so the only error `run` propagates is `StoreError.diskFull` — the router maps that to the
/// storage-full path; every other failure is degraded in-band and enqueued (never silence).
public struct TurnRunner: TurnDispatching {
  private let sessionMessages: any SessionMessageStore
  private let runs: any RunStore
  private let usageStore: any UsageStore
  private let outbox: any OutboxStore
  private let audit: any AuditLog
  private let agent: AgentRuntime
  private let budget: RunBudget
  private let systemPrompt: String
  /// Pokes the outbox dispatcher to drain after a commit. A no-op until Task 6 wires the dispatcher.
  private let notifyOutbox: @Sendable () -> Void
  private let logger: Logger

  /// Most-recent messages pulled for context; `ContextBuilder` then caps by grapheme budget (§9).
  private static let historyLimit = 50

  public init(
    sessionMessages: any SessionMessageStore,
    runs: any RunStore,
    usageStore: any UsageStore,
    outbox: any OutboxStore,
    audit: any AuditLog,
    agent: AgentRuntime,
    budget: RunBudget,
    systemPrompt: String,
    notifyOutbox: @escaping @Sendable () -> Void,
    logger: Logger
  ) {
    self.sessionMessages = sessionMessages
    self.runs = runs
    self.usageStore = usageStore
    self.outbox = outbox
    self.audit = audit
    self.agent = agent
    self.budget = budget
    self.systemPrompt = systemPrompt
    self.notifyOutbox = notifyOutbox
    self.logger = logger
  }

  public func run(sessionId: Int64, chatId: Int64) async throws {
    let now = Date()
    let runId = try runs.createRun(sessionId: sessionId, now: now)

    let history = try sessionMessages.loadRecentMessages(
      sessionId: sessionId,
      limit: Self.historyLimit
    )
    let (todayTokens, todayUSD) = try usageStore.todayTokensAndCost(now: now)

    let context = ContextBuilder.assemble(
      systemPrompt: systemPrompt,
      history: history,
      inputCapGraphemes: TokenEstimator.graphemeBudget(forInputTokens: budget.maxInputTokens)
    )

    let result = await agent.runTurn(
      runId: runId,
      sessionId: sessionId,
      chatId: chatId,
      context: context,
      todayTokens: todayTokens,
      todayUSD: todayUSD
    )

    try commit(result, runId: runId, sessionId: sessionId, chatId: chatId)
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
    chatId: Int64
  ) throws {
    let committedAt = Date()

    switch result {
    case .completed(let content, let usage):
      let turn = AssistantTurn(
        runId: runId,
        sessionId: sessionId,
        chatId: chatId,
        content: content,
        usage: usage,
        chunks: outboxChunks(for: content, chatId: chatId)
      )
      try runs.commitAssistantTurn(turn, now: committedAt)
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
    case .degraded(let degradationKind, let usage):
      if let usage {
        try usageStore.recordUsage(usage)
      }

      try degradeAndFail(
        runId: runId,
        sessionId: sessionId,
        chatId: chatId,
        message: Degradation.message(for: degradationKind),
        action: .turnDegraded,
        decision: degradationKind.rawValue,
        at: committedAt
      )
    case .budgetStopped(let cap):
      try degradeAndFail(
        runId: runId,
        sessionId: sessionId,
        chatId: chatId,
        message: Degradation.budget(cap: cap),
        action: .turnBudgetStopped,
        decision: cap,
        at: committedAt
      )
    }
  }

  /// The shared failure tail: enqueue the degradation reply, then fail the run, then audit. The
  /// enqueue precedes `failRun` so a crash between them leaves a PENDING reply for boot reconcile
  /// to deliver (F22) rather than losing it.
  private func degradeAndFail(  // swiftlint:disable:this function_parameter_count
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    message: String,
    action: AuditAction,
    decision: String,
    at committedAt: Date
  ) throws {
    _ = try outbox.claimOutbound(
      runId: runId,
      stepIndex: 0,
      chatId: chatId,
      payload: message,
      payloadHash: ContentHash.fnv1a(message)
    )
    try runs.failRun(runId: runId, now: committedAt)
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
