import ClawCore
import Foundation
import Logging

/// The pure orchestration of one blocking turn: preflight → typing + wall-clock deadline →
/// provider call → classify. No persistence or sending (the gateway owns that); all
/// collaborators are injected `ClawCore` protocols so tests drive it with mocks.
public struct AgentRuntime: Sendable {
  /// The routes a turn may drive. A turn starts on the primary unless it is cooling, and
  /// re-resolves its `ActiveRoute` when it fails over, so accounting and the budget gate follow
  /// whichever route really answered rather than one stamped at init.
  private let roster: ProviderRoster
  /// The primary's cooldown window, armed by a switch and cleared by a healthy answer. Absent when
  /// nothing composed one — a lone route has nowhere to switch, so it has nothing to remember.
  private let cooldown: (any PrimaryRouteCooldownTracking)?
  private let typingIndicator: any TypingIndicator
  private let draftStreamer: any RichDraftStreaming
  private let streamingEnabled: Bool
  private let attemptPolicy: AttemptRuntimePolicy

  // Route-independent: the resolvers and the run budget outlive any one route, so each
  // `ActiveRoute` is derived from them instead of replacing them. `internal`, not `private`, so the
  // extensions in the sibling runtime files reach them alongside the loop.
  let costResolver: CostResolver
  let usageResolver: UsageResolver
  let budget: RunBudget
  let toolDefinitions: [ToolDefinition]

  private let toolDispatcher: (any ToolDispatching)?

  private let usageStore: any UsageStore
  private let auditLog: any AuditLog
  /// Mints the identity each round-trip's usage row is recorded under. Injected so a test can pin
  /// the identities a run records rather than assert against a random UUID.
  private let providerCallIDGenerator: any ProviderCallIDGenerating
  /// Developer-facing diagnostics (swift-log). Distinct from `auditLog`, which is the durable
  /// business/security trail. Defaults to a no-op so tests stay silent unless they inject one.
  private let logger: Logger
  /// Injected so tests can script pacing (deadline, backoff) instead of waiting on wall-clock.
  private let clock: any Clock<Duration>
  private let now: @Sendable () -> ContinuousClock.Instant

  public init(
    roster: ProviderRoster,
    cooldown: (any PrimaryRouteCooldownTracking)? = nil,
    typingIndicator: any TypingIndicator,
    draftStreamer: any RichDraftStreaming,
    streamingEnabled: Bool,
    costResolver: CostResolver,
    usageResolver: UsageResolver = UsageResolver(),
    budget: RunBudget,
    toolDispatcher: (any ToolDispatching)? = nil,
    usageStore: any UsageStore,
    auditLog: any AuditLog,
    providerCallIDGenerator: any ProviderCallIDGenerating = UUIDProviderCallIDGenerator(),
    logger: Logger = Logger(label: "clawd.agent", factory: { _ in SwiftLogNoOpLogHandler() }),
    clock: any Clock<Duration>
  ) {
    self.init(
      roster: roster,
      cooldown: cooldown,
      typingIndicator: typingIndicator,
      draftStreamer: draftStreamer,
      streamingEnabled: streamingEnabled,
      attemptPolicy: .production,
      costResolver: costResolver,
      usageResolver: usageResolver,
      budget: budget,
      toolDispatcher: toolDispatcher,
      usageStore: usageStore,
      auditLog: auditLog,
      providerCallIDGenerator: providerCallIDGenerator,
      logger: logger,
      clock: clock,
      now: { ContinuousClock.now }
    )
  }

  package init(
    roster: ProviderRoster,
    cooldown: (any PrimaryRouteCooldownTracking)? = nil,
    typingIndicator: any TypingIndicator,
    draftStreamer: any RichDraftStreaming,
    streamingEnabled: Bool,
    attemptPolicy: AttemptRuntimePolicy = .production,
    costResolver: CostResolver,
    usageResolver: UsageResolver = UsageResolver(),
    budget: RunBudget,
    toolDispatcher: (any ToolDispatching)? = nil,
    usageStore: any UsageStore,
    auditLog: any AuditLog,
    providerCallIDGenerator: any ProviderCallIDGenerating = UUIDProviderCallIDGenerator(),
    logger: Logger = Logger(label: "clawd.agent", factory: { _ in SwiftLogNoOpLogHandler() }),
    clock: any Clock<Duration>,
    now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
  ) {
    self.roster = roster
    self.cooldown = cooldown
    self.typingIndicator = typingIndicator
    self.draftStreamer = draftStreamer
    self.streamingEnabled = streamingEnabled
    self.attemptPolicy = attemptPolicy

    self.costResolver = costResolver
    self.usageResolver = usageResolver
    self.budget = budget
    self.toolDefinitions = toolDispatcher?.definitions ?? []

    self.toolDispatcher = toolDispatcher

    self.usageStore = usageStore
    self.auditLog = auditLog
    self.providerCallIDGenerator = providerCallIDGenerator

    self.logger = logger

    self.clock = clock
    self.now = now
  }
}

extension AgentRuntime {
  // swiftlint:disable file_length function_parameter_count function_body_length cyclomatic_complexity
  /// The bounded agentic loop: one context assembly, then up to `maxTurns` round-trips
  /// with per-round-trip budget preflight, gated tool dispatch, and immediate usage/audit writes.
  /// A DELIBERATE SOFTENING of "no persistence here": `usageStore`/`auditLog` are injected
  /// so mid-run rows survive a crash. Throws ONLY `StoreError.diskFull`; every
  /// other failure resolves in-band to a `TurnResult`.
  public func runTurn(
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    buildResult: BuildResult,
    sessionTainted: Bool,
    sessionHasPrivateData: Bool,
    todayTokens: Int,
    todayUSD: Double,
    origin: RunOrigin = .interactive,
    proactiveTodayUSD: Double = 0,
    carryOver: ResumeUsage? = nil
  ) async throws -> TurnOutcome {
    let deadline = now() + .seconds(budget.wallClockDeadlineSeconds)
    var attemptState = AttemptRuntimeState(policy: attemptPolicy)
    let definitions = toolDefinitions
    let fenceLabels = ToolFenceLabels(definitions: definitions)
    // A cooling primary starts the turn on the fallback, so the round-trip is spent on a route
    // that can answer instead of re-proving the wall.
    var active = ActiveRoute(
      selection: roster.startingRoute(
        primaryIsCooling: await cooldown?.isCooling() == true
      ),
      budget: budget,
      costResolver: costResolver,
      usageResolver: usageResolver
    )
    var routeNotice: RouteNotice?

    // Turn-scoped logger: every line below inherits run/session metadata, so one `grep run=<id>`
    // ties the round-trips, tool calls, and outcome of a single turn together.
    var turnLog = logger
    for (key, value) in Self.turnMetadata(runId: runId, sessionId: sessionId) {
      turnLog[metadataKey: key] = value
    }
    let turnStart = now()
    turnLog.info(
      "turn started model=\(active.binding.configuredReference) origin=\(origin) contextMessages=\(buildResult.messages.count) streaming=\(streamingEnabled) tools=\(definitions.count)"
    )

    var wire = buildResult.messages
    var exchanges: [ToolExchange] = []

    var ingestedUntrusted = definitions.contains { definition in
      definition.metadataProvenance == .untrusted
    }
    var runPrivateData = false

    var pendingSuspension: PendingToolAction?

    // Seeded from the carried-over usage (nil = a fresh run; a continuation carries the run's
    // persisted totals so the tool-call / token / USD caps keep counting across the suspension).
    var proposedToolCalls = carryOver?.toolCalls ?? 0
    var recordedRunTokens = carryOver?.tokens ?? 0
    var recordedRunUSD = carryOver?.costUSD ?? 0.0

    // Terminal choke-point for the RESULT paths: every `return outcome(...)` flows through here, so a
    // turn that produces a `TurnOutcome` emits exactly one finished line (see `logFinish`). The
    // `StoreError.diskFull` fast-path throws to the gateway instead, which logs that terminal.
    func outcome(
      _ result: TurnResult,
      failureCause: AttemptFailureCause? = nil
    ) -> TurnOutcome {
      Self.logFinish(result, on: turnLog, elapsed: now() - turnStart)
      return TurnOutcome(
        result: result,
        exchanges: exchanges,
        ingestedUntrusted: ingestedUntrusted,
        hadPrivateData: buildResult.hasPrivateDataAccess || runPrivateData,
        routeNotice: routeNotice,
        attemptDiagnostics: attemptState.diagnostics(failureCause: failureCause)
      )
    }

    // The mid-dispatch wall-clock exit: the round's provider call already returned and its
    // intermediate row was recorded above under this same `callID`, so the conservative estimate this
    // books is idempotent on that identity — it degrades the turn without re-debiting the round. The
    // other two exits are handled elsewhere and account differently: the pre-send exit writes no row
    // (the call provably never issued), and a deadline that wins during the send surfaces as a thrown
    // cancellation marker the generic failure path classifies by its accounting disposition.
    func deadlineDegradation(_ callID: ProviderCallID) -> TurnResult {
      .degraded(
        .providerUnavailable,
        usage: active.accountant.conservativeRow(
          callID: callID,
          context: wire,
          tools: definitions,
          observedCompletionTokens: 0,
          runId: runId,
          sessionId: sessionId
        )
      )
    }

    // The wall-clock deadline is left per-segment by construction — it is recomputed at each
    // `runTurn` entry above; only the round count needs to account for rounds already consumed.
    let priorRounds = carryOver?.rounds ?? 0
    for roundTripIndex in 1...max(1, budget.maxTurns - priorRounds) {
      let callID = providerCallIDGenerator.next()
      // Scoped to this round-trip: when a re-issue on the next route also fails, the reported kind is
      // the one the round-trip started with, because "your plan quota is out" is the actionable fact
      // rather than whatever the fallback then said about itself. A later round-trip failing on the
      // route it is already using reports that route's own kind, so a refused credential or a
      // transient there is never masked by a wall the turn already moved past.
      var firstFailureKind: DegradationKind?

      let preflight = active.accountant.preflightEstimate(context: wire, tools: definitions)
      if preflight.inputTokens > budget.maxInputTokens {
        return outcome(.budgetStopped(cap: BudgetGate.perRunInputTokenCap))
      }

      let metered = active.binding.costPolicy == .metered
      if metered, recordedRunUSD + preflight.costUSD > budget.perRunUSD {
        return outcome(.budgetStopped(cap: BudgetGate.perRunSpendCap))
      }
      if case .deny(let cap) = active.gate.preflight(
        todayTokens: todayTokens + recordedRunTokens,
        todayUSD: todayUSD + recordedRunUSD,
        estimatedTotalTokens: preflight.totalTokens,
        estimatedCostUSD: preflight.costUSD,
        origin: origin,
        proactiveTodayUSD: proactiveTodayUSD + recordedRunUSD
      ) {
        return outcome(.budgetStopped(cap: cap))
      }

      guard Task.isCancelled == false else {
        return outcome(
          .degraded(.providerUnavailable, usage: nil),
          failureCause: .processInterruption
        )
      }

      let remaining = deadline - now()
      guard remaining > .zero else {
        turnLog.notice("round-trip \(roundTripIndex) wall-clock exhausted before send; degrading")
        return outcome(
          .degraded(.providerUnavailable, usage: nil),
          failureCause: .deadline
        )
      }

      turnLog.debug(
        "round-trip \(roundTripIndex) inputTokens~=\(preflight.inputTokens) estCostUSD=\(USD.precise(preflight.costUSD))"
      )
      if let admission = await attemptState.admission(
        roundTripIndex: roundTripIndex,
        priorRecordedTokens: recordedRunTokens,
        priorResponsesSends: roundTripIndex - 1
      ) {
        if case .deny(let cap) = admission {
          return outcome(.budgetStopped(cap: cap))
        }
      }
      guard Task.isCancelled == false else {
        return outcome(
          .degraded(.providerUnavailable, usage: nil),
          failureCause: .processInterruption
        )
      }
      // Re-issuing on the next route is one more attempt at the SAME round-trip, never a new one:
      // a turn that switches keeps the whole tool-call budget it started with.
      var response: ChatResponse
      attempts: while true {
        let sendBudget = deadline - now()
        guard sendBudget >= .seconds(1) else {
          turnLog.notice(
            "round-trip \(roundTripIndex) wall-clock cannot admit another bounded send; degrading"
          )
          return outcome(
            .degraded(.providerUnavailable, usage: nil),
            failureCause: .deadline
          )
        }
        let outputScope = attemptState.beginRound(outboundModel: active.binding.wireModel)
        let request = ChatRequest(
          model: active.binding.wireModel,
          messages: wire,
          maxOutputTokens: budget.maxOutputTokens,
          tools: definitions,
          sessionId: SessionTraceID.format(sessionID: sessionId),
          outputScope: outputScope,
          terminalValidationPolicy: attemptState.terminalValidationPolicy
        )
        if attemptState.accepts(outboundModel: request.model) == false {
          return outcome(
            .degraded(.providerUnavailable, usage: nil),
            failureCause: .modelIdentityMismatch
          )
        }
        do {
          response = try await roundTrip(
            provider: active.binding.provider,
            chatId: chatId,
            draftId: runId,
            request: request,
            deadlineSeconds: Int(sendBudget.components.seconds)
          )
          if attemptState.observe(response: response, outboundModel: request.model) {
            return outcome(
              .degraded(
                .providerUnavailable,
                usage: active.accountant.reconciledRow(
                  for: response,
                  callID: callID,
                  context: wire,
                  tools: definitions,
                  runId: runId,
                  sessionId: sessionId
                )
              ),
              failureCause: .modelIdentityMismatch
            )
          }

          do {
            try attemptState.finalize(response, scope: outputScope)
          } catch {
            return outcome(
              .degraded(
                .providerUnavailable,
                usage: active.accountant.reconciledRow(
                  for: response,
                  callID: callID,
                  context: wire,
                  tools: definitions,
                  runId: runId,
                  sessionId: sessionId
                )
              ),
              failureCause: .localOutputLimit
            )
          }
          break attempts
        } catch {
          let failure = AgentFailureClassification(error: error)
          let reportedKind = firstFailureKind ?? failure.degradationKind
          firstFailureKind = reportedKind

          guard
            let persistence = RouteSwitch.permits(error),
            let next = roster.failover(from: active.position)
          else {
            turnLog.warning("round-trip \(roundTripIndex) provider error (degrading): \(error)")
            return outcome(
              failureOutcome(
                error,
                callID: callID,
                context: wire,
                runId: runId,
                sessionId: sessionId,
                accountant: active.accountant,
                degradationKind: reportedKind
              ),
              failureCause: failure.attemptFailureCause
            )
          }

          let previous = active.binding.configuredReference
          await cooldown?.arm(
            persistence: persistence,
            retryAfterSeconds: RouteSwitch.retryAfterSeconds(of: error)
          )
          active = ActiveRoute(
            selection: next,
            budget: budget,
            costResolver: costResolver,
            usageResolver: usageResolver
          )
          let reason = failure.degradationKind.auditDecision
          let successor = active.binding.configuredReference
          turnLog.notice(
            "route switch from=\(previous) to=\(successor) reason=\(reason) cooldown=\(persistence)"
          )
          routeNotice = .switched(from: previous, to: successor)
          try recordAudit(
            AuditEvent(
              actor: .system,
              action: .providerFallback,
              decision: reason,
              runId: runId,
              sessionId: sessionId,
              ts: Date()
            ),
            runId: runId,
            sessionId: sessionId
          )
        }
      }

      // The route answered, so a primary that had been walled off is healthy again. Only the first
      // answering round-trip owes the notice; a later one finds the window already cleared.
      if active.position == .primary, routeNotice == nil {
        routeNotice = await primaryRecoveryNotice(binding: active.binding)
      }

      guard response.toolCalls.isEmpty == false else {
        let classified = classify(
          response: response,
          callID: callID,
          context: wire,
          runId: runId,
          sessionId: sessionId,
          accountant: active.accountant
        )
        return outcome(classified)
      }

      let intermediate = active.accountant.reconciledRow(
        for: response,
        callID: callID,
        context: wire,
        tools: definitions,
        runId: runId,
        sessionId: sessionId
      )
      do {
        try usageStore.recordUsage(intermediate)
      } catch StoreError.diskFull {
        throw StoreError.diskFull
      } catch {
        turnLog.warning("mid-run usage write failed; halting provider calls: \(error)")
        return outcome(.degraded(.accountingFailed, usage: nil))
      }
      recordedRunTokens += intermediate.promptTokens + intermediate.completionTokens
      recordedRunUSD += intermediate.costUSD
      if response.usage == nil {
        attemptState.recordMissingUsage(intermediate)
      }

      await typingIndicator.sendTyping(chatId: chatId)
      var observations: [ToolObservation] = []
      for call in response.toolCalls {
        proposedToolCalls += 1
        guard proposedToolCalls <= budget.maxToolCalls else {
          return outcome(.budgetStopped(cap: "per-run tool-call"))
        }

        guard deadline > now() else {
          return outcome(
            deadlineDegradation(callID),
            failureCause: .deadline
          )
        }

        let context = ToolDispatchContext(
          sessionTainted: sessionTainted,
          runIngestedUntrusted: ingestedUntrusted,
          assemblyPrivateData: buildResult.hasPrivateDataAccess,
          runPrivateData: runPrivateData,
          sessionHasPrivateData: sessionHasPrivateData,
          approvalAlreadyPending: pendingSuspension != nil
        )

        guard let toolDispatcher else {
          observations.append(
            ToolObservation(
              callId: call.id,
              toolName: call.name,
              content: "No tools are available.",
              status: .error,
              ingestedUntrusted: false
            )
          )
          continue
        }

        turnLog.debug("tool \(call.name) invoked")
        let toolStart = now()
        let dispatched = await toolDispatcher.dispatch(call: call, context: context)
        turnLog.debug(
          "tool \(call.name) done decision=\(dispatched.observation.status.rawValue) bytes=\(dispatched.observation.content.utf8.count) ms=\(Self.millis(now() - toolStart))"
        )

        if pendingSuspension == nil, let recordedAction = dispatched.requiresApproval {
          pendingSuspension = PendingToolAction(toolCallId: call.id, recorded: recordedAction)
          continue
        }

        try recordToolAudit(for: call, outcome: dispatched, runId: runId, sessionId: sessionId)

        observations.append(dispatched.observation)
        if dispatched.observation.ingestedUntrusted {
          ingestedUntrusted = true
        }
        if dispatched.observation.readPrivateData {
          runPrivateData = true
        }
      }

      wire.append(
        ChatMessage(
          role: .assistant,
          content: response.content,
          toolCalls: response.toolCalls,
          providerState: response.providerState
        )
      )
      for observation in observations {
        wire.append(
          ChatMessage(
            role: .tool,
            content: LabeledContextFactory.make(
              label: fenceLabels.label(forToolNamed: observation.toolName),
              content: observation.content
            ).render(),
            toolCallId: observation.callId
          )
        )
      }

      exchanges.append(
        ToolExchange(
          assistantContent: response.content,
          toolCalls: response.toolCalls,
          observations: observations,
          providerState: response.providerState
        )
      )

      if let pending = pendingSuspension {
        return outcome(.suspended(pending: pending, usage: intermediate))
      }
    }

    return outcome(.budgetStopped(cap: "per-run turn"))
  }
  // swiftlint:enable function_parameter_count function_body_length cyclomatic_complexity
}

// MARK: - Turn Diagnostics

private extension AgentRuntime {
  /// The correlation fields stamped on every developer log line for one turn, so a single
  /// `grep run=<id>` ties the turn's round-trips, tool calls, and outcome together.
  static func turnMetadata(runId: Int64, sessionId: Int64) -> Logger.Metadata {
    ["run": "\(runId)", "session": "\(sessionId)"]
  }

  /// Emits the one finished line for a turn; its level reflects severity — completed → info,
  /// budget-stopped → notice (an expected guard), degraded → warning (something went wrong). Only
  /// safe fields (counts, tokens, cost, elapsed) are logged, never the reply text.
  static func logFinish(_ result: TurnResult, on log: Logger, elapsed: Duration) {
    let elapsedMillis = millis(elapsed)
    switch result {
    case .completed(let content, let usage, _):
      log.info(
        "turn finished completed chars=\(content.count) tokens=\(usage.promptTokens + usage.completionTokens) usd=\(USD.precise(usage.costUSD)) ms=\(elapsedMillis)"
      )
    case .degraded(let kind, let usage):
      let tokens = usage.map { "\($0.promptTokens + $0.completionTokens)" } ?? "n/a"
      log.warning(
        "turn finished degraded kind=\(kind.auditDecision) tokens=\(tokens) ms=\(elapsedMillis)"
      )
    case .budgetStopped(let cap):
      log.notice("turn finished budget-stopped cap=\(cap) ms=\(elapsedMillis)")
    case .suspended(let pending, let usage):
      log.info(
        "turn finished suspended tool=\(pending.recorded.tool) tokens=\(usage.promptTokens + usage.completionTokens) ms=\(elapsedMillis)"
      )
    }
  }

  /// Whole milliseconds of a `Duration`, for compact latency fields in developer logs.
  static func millis(_ duration: Duration) -> Int64 {
    let parts = duration.components
    return parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000
  }
}

// MARK: - Round-Trip Recording

private extension AgentRuntime {
  /// One audit row per dispatch, written immediately, blocked calls included.
  func recordToolAudit(
    for call: ToolCall,
    outcome dispatched: ToolDispatchOutcome,
    runId: Int64,
    sessionId: Int64
  ) throws {
    try recordAudit(
      AuditEvent(
        actor: .assistant,
        action: .toolCall,
        tool: call.name,
        argsRedacted: dispatched.argsRedacted,
        resultSize: dispatched.observation.content.utf8.count,
        decision: dispatched.observation.status.rawValue,
        runId: runId,
        sessionId: sessionId,
        ts: Date()
      ),
      runId: runId,
      sessionId: sessionId
    )
  }

  /// Writes one audit row on the turn's single throwing contract. Audit is observability, not a
  /// gate: only a full disk stops the turn, any other write failure logs and the run continues.
  func recordAudit(_ event: AuditEvent, runId: Int64, sessionId: Int64) throws {
    do {
      try auditLog.appendAudit(event)
    } catch StoreError.diskFull {
      throw StoreError.diskFull
    } catch {
      logger.warning(
        "audit write failed (continuing): \(error)",
        metadata: Self.turnMetadata(runId: runId, sessionId: sessionId)
      )
    }
  }
}

// MARK: - Route Health

private extension AgentRuntime {
  /// Records that the primary answered: drops its cooldown window and reports the single notice
  /// owed when that window had lapsed rather than been cleared, so exactly one turn tells the owner
  /// the primary is carrying traffic again.
  func primaryRecoveryNotice(binding: LLMRouteBinding) async -> RouteNotice? {
    guard let cooldown else {
      return nil
    }
    let lapsed = await cooldown.recordSuccess()
    return lapsed ? .restored(route: binding.configuredReference) : nil
  }
}

// MARK: - Provider Round Trip

private extension AgentRuntime {
  /// One provider round-trip inside the SHARED wall-clock window: streaming when enabled,
  /// falling back to typing on a connect failure or a clean pre-stream rejection, else plain typing.
  /// `deadlineSeconds` is the REMAINING run budget, not a fresh 180 s. Throws the provider/deadline
  /// error; the loop maps it.
  func roundTrip(
    provider: any LLMProvider,
    chatId: Int64,
    draftId: Int64,
    request: ChatRequest,
    deadlineSeconds: Int
  ) async throws -> ChatResponse {
    guard streamingEnabled else {
      return try await runTypingTurn(
        provider: provider,
        chatId: chatId,
        request: request,
        deadlineSeconds: deadlineSeconds
      )
    }

    // The streaming attempt can burn part of the round's window on a slow connect before it fails,
    // so the buffered reattempt is bounded by what is LEFT, not the round's original window — else one
    // round could run up to roughly twice the turn's remaining wall clock before the outer loop
    // re-checks the deadline.
    let streamStart = ContinuousClock.now
    do {
      return try await runStreamingTurn(
        provider: provider,
        chatId: chatId,
        draftId: draftId,
        request: request,
        deadlineSeconds: deadlineSeconds
      )
    } catch let error where ProviderError.cause(of: error)?.allowsPreInferenceReissue == true {
      guard attemptPolicy.streamingReattemptPolicy == .bufferedWhenSafe else {
        throw error
      }
      // connectFailed: nothing was transmitted. rejected: the head carried an error status before
      // any SSE bytes, so the server generated nothing — the no-double-issue rationale does
      // not apply. Either way one blocking attempt is safe; `complete` brings its own retry
      // budget, backoff, and Retry-After handling, all inside the remaining wall-clock window.
      // Reading through `cause(of:)` matches both shapes: the streaming runtime wraps its failures
      // in a `ProviderFailure` envelope, and matching only the bare error would let the wrapper
      // silently defeat the one-time buffered fallback.
      return try await runTypingTurn(
        provider: provider,
        chatId: chatId,
        request: request,
        deadlineSeconds: Self.remainingDeadlineSeconds(total: deadlineSeconds, since: streamStart)
      )
    }
  }

  /// The wall-clock budget left for the buffered reattempt after the streaming attempt consumed part
  /// of the round's window. Floored at one second so `complete` still receives a positive bound even
  /// when the streaming attempt already exhausted the window.
  static func remainingDeadlineSeconds(total: Int, since start: ContinuousClock.Instant) -> Int {
    let elapsed = Int((ContinuousClock.now - start).components.seconds)
    return max(1, total - elapsed)
  }

  func runStreamingTurn(
    provider: any LLMProvider,
    chatId: Int64,
    draftId: Int64,
    request: ChatRequest,
    deadlineSeconds: Int
  ) async throws -> ChatResponse {
    let runtime = StreamingTurnRuntime(
      provider: provider,
      typingIndicator: typingIndicator,
      draftStreamer: draftStreamer,
      wallClockDeadlineSeconds: deadlineSeconds,
      clock: clock
    )
    return try await runtime.run(chatId: chatId, draftId: draftId, request: request)
  }

  func runTypingTurn(
    provider: any LLMProvider,
    chatId: Int64,
    request: ChatRequest,
    deadlineSeconds: Int
  ) async throws -> ChatResponse {
    let runtime = TypingTurnRuntime(
      provider: provider,
      typingIndicator: typingIndicator,
      wallClockDeadlineSeconds: deadlineSeconds,
      clock: clock
    )
    return try await runtime.run(chatId: chatId, request: request)
  }
}
