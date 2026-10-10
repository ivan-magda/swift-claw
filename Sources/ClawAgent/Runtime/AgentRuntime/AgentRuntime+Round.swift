import ClawCore
import Foundation
import Logging

// MARK: - Round-Trip

extension AgentRuntime {
  /// Runs one round-trip: admit it, send it, then either classify the final answer or record the
  /// round's usage, run its tool batch, and extend the transcript. Returns nil to run the next one.
  func runRound(_ index: Int, turn: TurnFrame, state: inout TurnState) async throws -> TurnExit? {
    let plan = RoundPlan(
      index: index,
      callID: providerCallIDGenerator.next(),
      wire: state.transcript.wire,
      turn: turn
    )

    let refusal = await admitRound(
      plan,
      route: state.route.active,
      ledger: state.ledger,
      attempts: state.attempts
    )
    if let refusal {
      return refusal
    }

    await turn.progress?.publish(.modelStarted(providerCallID: plan.callID.rawValue))

    let round: AnsweredRound
    switch try await sendRound(plan, route: &state.route, attempts: &state.attempts) {
    case .proceed(let answered):
      round = answered
    case .exit(let exit):
      return exit
    }
    await state.route.recordAnswer()

    guard round.response.toolCalls.isEmpty == false else {
      return TurnExit(classify(round))
    }

    let usage: ProviderUsage
    switch try recordIntermediateUsage(round, ledger: &state.ledger, attempts: &state.attempts) {
    case .proceed(let recorded):
      usage = recorded
    case .exit(let exit):
      return exit
    }

    let batch: ToolBatch
    switch try await runToolBatch(round, ledger: &state.ledger, trust: &state.trust) {
    case .proceed(let drained):
      batch = drained
    case .exit(let exit):
      return exit
    }

    state.transcript.append(round.response, observations: batch.observations)
    if batch.interrupted {
      return .interrupted
    }
    if let pending = batch.pending {
      return TurnExit(.suspended(pending: pending, usage: usage))
    }

    return nil
  }
}

// MARK: - Admission

private extension AgentRuntime {
  /// Refuses a round before anything is sent: the spend caps, cancellation, the wall clock, then the
  /// admission hook, with cancellation checked again once the hook returns.
  func admitRound(
    _ plan: RoundPlan,
    route: ActiveRoute,
    ledger: RunSpendLedger,
    attempts: AttemptRuntimeState
  ) async -> TurnExit? {
    let preflight = route.accountant.preflightEstimate(context: plan.wire, tools: toolDefinitions)
    let spendRefusal = route.accountant.refusal(for: preflight) { estimate in
      ledger.preflight(estimate, on: route)
    }

    if let spendRefusal {
      plan.turn.log.notice(
        """
        round-trip \(plan.index) refused cap=\(spendRefusal.cap) \
        estCostUSD=\(USD.precise(preflight.costUSD)) costSource=\(preflight.costSource.rawValue)
        """
      )
      return .budgetStopped(cap: spendRefusal.cap, unpricedModel: spendRefusal.unpricedModel)
    }

    guard Task.isCancelled == false else {
      return .interrupted
    }

    guard plan.turn.deadline - now() > .zero else {
      plan.turn.log.notice("round-trip \(plan.index) wall-clock exhausted before send; degrading")
      return .deadline
    }

    plan.turn.log.debug(
      """
      round-trip \(plan.index) inputTokens~=\(preflight.inputTokens) \
      estCostUSD=\(USD.precise(preflight.costUSD))
      """
    )
    let admission = await attempts.admission(
      roundTripIndex: plan.index,
      priorRecordedTokens: ledger.recordedTokens,
      priorResponsesSends: plan.index - 1
    )
    if case .deny(let cap)? = admission {
      return .budgetStopped(cap: cap)
    }

    guard Task.isCancelled == false else {
      return .interrupted
    }

    return nil
  }
}

// MARK: - Send

private extension AgentRuntime {
  /// Sends the round on the active route. A failure that permits a switch re-issues the SAME
  /// round-trip on the fallback, never a new one: same call id, no second budget check, so a turn
  /// that switches keeps the whole round and tool-call budget it started with.
  func sendRound(
    _ plan: RoundPlan,
    route: inout TurnRoute,
    attempts: inout AttemptRuntimeState
  ) async throws -> TurnStep<AnsweredRound> {
    // Scoped to this round-trip: when a re-issue on the next route also fails, the reported kind is
    // the one the round-trip started with, because "your plan quota is out" is the actionable fact
    // rather than whatever the fallback then said about itself. A later round-trip failing on the
    // route it is already using reports that route's own kind, so a refused credential or a
    // transient there is never masked by a wall the turn already moved past.
    var firstFailureKind: DegradationKind?
    while true {
      let sendBudget = plan.turn.deadline - now()
      guard sendBudget >= .seconds(1) else {
        plan.turn.log.notice(
          "round-trip \(plan.index) wall-clock cannot admit another bounded send; degrading"
        )
        return .exit(.deadline)
      }

      let progressExplanationsEnabled =
        streamingEnabled
        && plan.turn.scope.origin == .interactive
        && plan.turn.scope.mode == .direct
        && plan.turn.progress?.explanationsEnabled == true
      let outputScope = attempts.beginRound(outboundModel: route.active.binding.wireModel)
      let request = ChatRequest(
        model: route.active.binding.wireModel,
        messages: plan.wire,
        maxOutputTokens: budget.maxOutputTokens,
        tools: toolDefinitions,
        sessionID: SessionTraceID.format(sessionID: plan.turn.scope.sessionID),
        progressExplanationsEnabled: progressExplanationsEnabled,
        outputScope: outputScope,
        terminalValidationPolicy: attempts.terminalValidationPolicy
      )

      if attempts.accepts(outboundModel: request.model) == false {
        let mismatch = TurnResult.degraded(.providerUnavailable, usage: nil)
        return .exit(TurnExit(mismatch, failureCause: .modelIdentityMismatch))
      }

      let response: ChatResponse
      do {
        response = try await roundTrip(
          provider: route.active.binding.provider,
          target: plan.turn.scope.progressTarget,
          request: request,
          deadlineSeconds: Int(sendBudget.components.seconds),
          progress: plan.turn.progress
        )
      } catch {
        let failure = AgentFailureClassification(error: error)
        let reportedKind = firstFailureKind ?? failure.degradationKind
        firstFailureKind = reportedKind

        let transition = await route.switchRoute(after: error)
        guard let transition else {
          plan.turn.log.warning("round-trip \(plan.index) provider error (degrading): \(error)")
          let result = failureOutcome(
            error,
            plan: plan,
            accountant: route.active.accountant,
            degradationKind: reportedKind
          )
          return .exit(TurnExit(result, failureCause: failure.attemptFailureCause))
        }

        try recordRouteSwitch(
          transition,
          reason: failure.degradationKind,
          turn: plan.turn
        )

        continue
      }

      let round = AnsweredRound(
        plan: plan,
        response: response,
        accountant: route.active.accountant
      )

      return verify(
        round,
        outboundModel: request.model,
        outputScope: outputScope,
        attempts: &attempts
      )
    }
  }

  /// Holds an answer to the attempt policy: a reply from an unexpected model, or one past the local
  /// output limit, degrades the turn while still booking the round's reconciled usage.
  func verify(
    _ round: AnsweredRound,
    outboundModel: String,
    outputScope: AttemptOutputScope?,
    attempts: inout AttemptRuntimeState
  ) -> TurnStep<AnsweredRound> {
    let modelMismatch = attempts.observe(response: round.response, outboundModel: outboundModel)
    if modelMismatch {
      let mismatch = TurnResult.degraded(.providerUnavailable, usage: reconciledUsage(for: round))
      return .exit(TurnExit(mismatch, failureCause: .modelIdentityMismatch))
    }

    do {
      try attempts.finalize(round.response, scope: outputScope)
    } catch {
      let overrun = TurnResult.degraded(.providerUnavailable, usage: reconciledUsage(for: round))
      return .exit(TurnExit(overrun, failureCause: .localOutputLimit))
    }

    return .proceed(round)
  }

  /// Logs and audits a route switch; the audit decision is the failure kind that caused it.
  func recordRouteSwitch(
    _ transition: TurnRoute.Transition,
    reason kind: DegradationKind,
    turn: TurnFrame
  ) throws {
    let reason = kind.auditDecision
    turn.log.notice(
      """
      route switch from=\(transition.previous) to=\(transition.successor) \
      reason=\(reason) cooldown=\(transition.persistence)
      """
    )
    try recordAudit(
      AuditEvent(
        actor: .system,
        action: .providerFallback,
        decision: reason,
        runID: turn.scope.runID,
        sessionID: turn.scope.sessionID,
        ts: Date()
      ),
      runID: turn.scope.runID,
      sessionID: turn.scope.sessionID
    )
  }
}
