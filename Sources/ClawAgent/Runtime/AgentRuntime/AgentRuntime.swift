import ClawCore
import Foundation
import Logging

/// Runs provider rounds and gated tools under the run's budgets.
///
/// The runtime records intermediate usage and audit events; the gateway owns terminal persistence
/// and delivery. Collaborators are injected through ClawCore protocols.
public struct AgentRuntime: Sendable {
  /// The routes a turn may drive.
  ///
  /// A turn starts on the primary unless it is cooling, and re-resolves its `ActiveRoute` when it
  /// fails over, so accounting and the budget gate follow whichever route really answered rather
  /// than one stamped at init.
  private let roster: ProviderRoster
  /// The primary's cooldown window, armed by a switch and cleared by a healthy answer.
  ///
  /// Absent when nothing composed one — a lone route has nowhere to switch, so it has nothing to
  /// remember.
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
  /// Mints the identity each round-trip's usage row is recorded under.
  ///
  /// Injected so a test can pin the identities a run records rather than assert against a random
  /// UUID.
  private let providerCallIDGenerator: any ProviderCallIDGenerating
  /// Developer-facing diagnostics (swift-log).
  ///
  /// Distinct from `auditLog`, which is the durable business/security trail. Defaults to a no-op so
  /// tests stay silent unless they inject one.
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
    logger: Logger = Logger(label: "clawd.agent") { _ in
      SwiftLogNoOpLogHandler()
    },
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
      clock: clock
    ) {
      ContinuousClock.now
    }
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
    logger: Logger = Logger(label: "clawd.agent") { _ in
      SwiftLogNoOpLogHandler()
    },
    clock: any Clock<Duration>,
    now: @escaping @Sendable () -> ContinuousClock.Instant = {
      ContinuousClock.now
    }
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
  /// Runs the bounded provider and tool loop using an assembled context.
  ///
  /// Each round checks budgets and policy before dispatch and records intermediate usage and audit
  /// events. Failures other than disk-full resolve in the returned outcome.
  ///
  /// - Parameters:
  ///   - runID: The durable run to charge and audit.
  ///   - sessionID: The conversation that owns the run.
  ///   - chatID: The chat receiving progress updates.
  ///   - buildResult: The assembled messages and their privacy and policy metadata.
  ///   - sessionTainted: The session's persisted untrusted-ingestion state at entry.
  ///   - hasPinnedLessons: Whether non-empty model-written lessons are present, arming the run's
  ///     untrusted-ingestion flag before the first dispatch.
  ///   - sessionHasPrivateData: The session's persisted private-data flag at entry.
  ///   - todayTokens: The persisted daily token total loaded when this run segment starts.
  ///   - todayUSD: The persisted daily metered spend loaded when this run segment starts.
  ///   - origin: Selects interactive or proactive budget and privilege restrictions.
  ///   - proactiveTodayUSD: The persisted daily proactive spend loaded at segment start.
  ///   - carryOver: Usage already recorded for a suspended run, or nil for a fresh run.
  ///   - mode: The conversation's frozen direct or group mode.
  ///   - threadID: The forum topic receiving progress, or nil for a chat without a topic ID.
  ///   - requesterUserID: The original sender whose identity follows group actions.
  /// - Returns: The run-segment result, including approval suspension, plus the tool exchanges,
  ///   accumulated trust flags, and route notice needed by the gateway.
  /// - Throws: `StoreError.diskFull` when a required intermediate write cannot fit on disk.
  public func runTurn(
    runID: Int64,
    sessionID: Int64,
    chatID: Int64,
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
    threadID: Int64? = nil,
    requesterUserID: Int64? = nil
  ) async throws -> TurnOutcome {
    let deadline = now() + .seconds(budget.wallClockDeadlineSeconds)
    var attemptState = AttemptRuntimeState(policy: attemptPolicy)
    let definitions = toolDefinitions
    let fenceLabels = ToolFenceLabels(definitions: definitions)
    // A cooling primary starts the turn on the fallback, so the round-trip is spent on a route
    // that can answer instead of re-proving the wall.
    var active = ActiveRoute(
      selection: roster.startingRoute(primaryIsCooling: await cooldown?.isCooling() == true),
      budget: budget,
      costResolver: costResolver,
      usageResolver: usageResolver
    )
    var routeNotice: RouteNotice?

    // Turn-scoped logger: every line below inherits run/session metadata, so one `grep run=<id>`
    // ties the round-trips, tool calls, and outcome of a single turn together.
    var turnLog = logger
    let metadata = Self.turnMetadata(
      runID: runID,
      sessionID: sessionID,
      mode: mode,
      threadID: threadID
    )
    for (key, value) in metadata {
      turnLog[metadataKey: key] = value
    }
    let turnStart = now()
    turnLog.info(
      """
      turn started model=\(active.binding.configuredReference) \
      origin=\(origin) \
      contextMessages=\(buildResult.messages.count) \
      streaming=\(streamingEnabled) \
      tools=\(definitions.count)
      """
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
    func outcome(_ result: TurnResult, failureCause: AttemptFailureCause? = nil) -> TurnOutcome {
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
          runID: runID,
          sessionID: sessionID
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
        return outcome(.degraded(.providerUnavailable, usage: nil), failureCause: .deadline)
      }

      turnLog.debug(
        """
        round-trip \(roundTripIndex) inputTokens~=\(preflight.inputTokens) \
        estCostUSD=\(USD.precise(preflight.costUSD))
        """
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
          return outcome(.degraded(.providerUnavailable, usage: nil), failureCause: .deadline)
        }
        let outputScope = attemptState.beginRound(outboundModel: active.binding.wireModel)
        let request = ChatRequest(
          model: active.binding.wireModel,
          messages: wire,
          maxOutputTokens: budget.maxOutputTokens,
          tools: definitions,
          sessionID: SessionTraceID.format(sessionID: sessionID),
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
            target: TurnProgressTarget(chatID: chatID, threadID: threadID, draftID: runID),
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
                  runID: runID,
                  sessionID: sessionID
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
                  runID: runID,
                  sessionID: sessionID
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

          guard let persistence = RouteSwitch.permits(error),
                let next = roster.failover(from: active.position)
          else {
            turnLog.warning("round-trip \(roundTripIndex) provider error (degrading): \(error)")
            return outcome(
              failureOutcome(
                error,
                callID: callID,
                context: wire,
                runID: runID,
                sessionID: sessionID,
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
              runID: runID,
              sessionID: sessionID,
              ts: Date()
            ),
            runID: runID,
            sessionID: sessionID
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
          runID: runID,
          sessionID: sessionID,
          accountant: active.accountant
        )
        return outcome(classified)
      }

      let intermediate = active.accountant.reconciledRow(
        for: response,
        callID: callID,
        context: wire,
        tools: definitions,
        runID: runID,
        sessionID: sessionID
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

      await typingIndicator.sendTyping(chatID: chatID, messageThreadID: threadID)
      var observations: [ToolObservation] = []
      for call in response.toolCalls {
        guard !Task.isCancelled else {
          return outcome(
            .degraded(.providerUnavailable, usage: nil),
            failureCause: .processInterruption
          )
        }
        proposedToolCalls += 1
        guard proposedToolCalls <= budget.maxToolCalls else {
          return outcome(.budgetStopped(cap: "per-run tool-call"))
        }

        guard deadline > now() else {
          return outcome(deadlineDegradation(callID), failureCause: .deadline)
        }

        let effectiveRequesterUserID: Int64?
        if origin == .interactive {
          if let requesterUserID {
            effectiveRequesterUserID = requesterUserID
          } else if mode == .direct {
            effectiveRequesterUserID = chatID
          } else {
            effectiveRequesterUserID = nil
          }
        } else {
          effectiveRequesterUserID = nil
        }

        let context = ToolDispatchContext(
          sessionTainted: sessionTainted,
          runIngestedUntrusted: ingestedUntrusted,
          assemblyPrivateData: buildResult.hasPrivateDataAccess,
          runPrivateData: runPrivateData,
          sessionHasPrivateData: sessionHasPrivateData,
          approvalAlreadyPending: pendingSuspension != nil,
          mode: mode,
          executionContext: ToolExecutionContext(
            runID: runID,
            sessionID: sessionID,
            chatID: chatID,
            requesterUserID: effectiveRequesterUserID,
            origin: origin,
            mode: mode,
            toolCallID: call.id,
            approvalID: nil
          )
        )

        guard let toolDispatcher else {
          observations.append(
            ToolObservation(
              callID: call.id,
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
          """
          tool \(call.name) done decision=\(dispatched.observation.status.rawValue) \
          bytes=\(dispatched.observation.content.utf8.count) \
          ms=\(Self.millis(now() - toolStart))
          """
        )

        if pendingSuspension == nil, let recordedAction = dispatched.requiresApproval {
          pendingSuspension = PendingToolAction(toolCallID: call.id, recorded: recordedAction)
          continue
        }

        try recordToolAudit(for: call, outcome: dispatched, runID: runID, sessionID: sessionID)

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
            toolCallID: observation.callID
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
  }  // swiftlint:enable function_parameter_count function_body_length cyclomatic_complexity
}
