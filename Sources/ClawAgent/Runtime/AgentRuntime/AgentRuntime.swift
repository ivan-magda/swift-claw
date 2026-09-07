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
  let cooldown: (any PrimaryRouteCooldownTracking)?
  let typingIndicator: any TypingIndicator
  let draftStreamer: any RichDraftStreaming
  let streamingEnabled: Bool
  let attemptPolicy: AttemptRuntimePolicy

  // Route-independent: the resolvers and the run budget outlive any one route, so each
  // `ActiveRoute` is derived from them instead of replacing them. `internal`, not `private`, so the
  // extensions in the sibling runtime files reach them alongside the loop.
  let costResolver: CostResolver
  let usageResolver: UsageResolver
  let budget: RunBudget
  let toolDefinitions: [ToolDefinition]

  private let toolDispatcher: (any ToolDispatching)?

  private let usageStore: any UsageStore
  let auditLog: any AuditLog
  /// Mints the identity each round-trip's usage row is recorded under. Injected so a test can pin
  /// the identities a run records rather than assert against a random UUID.
  private let providerCallIDGenerator: any ProviderCallIDGenerating
  /// Developer-facing diagnostics (swift-log). Distinct from `auditLog`, which is the durable
  /// business/security trail. Defaults to a no-op so tests stay silent unless they inject one.
  let logger: Logger
  /// Injected so tests can script pacing (deadline, backoff) instead of waiting on wall-clock.
  let clock: any Clock<Duration>
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
  // swiftlint:disable function_parameter_count function_body_length cyclomatic_complexity
  /// The bounded agentic loop: one context assembly, then up to `maxTurns` round-trips
  /// with per-round-trip budget preflight, gated tool dispatch, and immediate usage/audit writes.
  /// A DELIBERATE SOFTENING of "no persistence here": `usageStore`/`auditLog` are injected
  /// so mid-run rows survive a crash. Throws ONLY `StoreError.diskFull`; every
  /// other failure resolves in-band to a `TurnResult`.
  ///
  /// - Parameter hasPinnedLessons: whether the assembled context carries a non-empty pinned lesson
  ///   set. A model wrote those lessons, so they arm the run's untrusted-ingestion flag before the
  ///   first dispatch instead of waiting for a tool observation to do it.
  public func runTurn(
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    buildResult: BuildResult,
    sessionTainted: Bool,
    hasPinnedLessons: Bool,
    sessionHasPrivateData: Bool,
    todayTokens: Int,
    todayUSD: Double,
    origin: RunOrigin = .interactive,
    proactiveTodayUSD: Double = 0,
    carryOver: ResumeUsage? = nil,
    mode: ChatMode = .direct,
    threadId: Int64? = nil
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
    let metadata = Self.turnMetadata(
      runId: runId,
      sessionId: sessionId,
      mode: mode,
      threadId: threadId
    )
    for (key, value) in metadata {
      turnLog[metadataKey: key] = value
    }
    let turnStart = now()
    turnLog.info(
      "turn started model=\(active.binding.configuredReference) origin=\(origin) contextMessages=\(buildResult.messages.count) streaming=\(streamingEnabled) tools=\(definitions.count)"
    )

    var wire = buildResult.messages
    var exchanges: [ToolExchange] = []

    let untrustedToolMetadata = definitions.contains { definition in
      definition.metadataProvenance == .untrusted
    }
    var ingestedUntrusted = untrustedToolMetadata || hasPinnedLessons
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
            target: TurnProgressTarget(chatId: chatId, threadId: threadId, draftId: runId),
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

      await typingIndicator.sendTyping(chatId: chatId, messageThreadId: threadId)
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
          approvalAlreadyPending: pendingSuspension != nil,
          mode: mode
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
