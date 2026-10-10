import ClawCore
import Foundation
import Logging

// MARK: - Result Classification

extension AgentRuntime {
  /// The single accounting decision for every natural failure and cancellation. It reads the
  /// vendor-neutral disposition — `ProviderFailure.accounting` when the provider tagged one — never
  /// which execution method the caller used. `notStarted` proves the model was never asked, so no
  /// row is written; `mayHaveStarted` may already owe tokens, so a conservative row is.
  ///
  /// Cancellation is the owner's own doing, never a provider outage: raw cancellation generated
  /// nothing to bill, while the typed inference-cancellation marker says the model may have been
  /// asked anyway. Both flow to the run-cancel path, where a cancelled run's commit is arbitrated
  /// away before any outage copy can reach the owner.
  ///
  /// `accountant` is bound to the route that made this call. `degradationKind` is selected before
  /// accounting and may preserve the primary route's actionable failure when its fallback also fails.
  func failureOutcome(
    _ error: any Error,
    plan: RoundPlan,
    accountant: ProviderUsageAccountant,
    degradationKind: DegradationKind
  ) -> TurnResult {
    if let racedSuccess = error as? RacedDeadlineSuccess {
      // A real response landed alongside a won deadline: its usage is authoritative
      let round = AnsweredRound(plan: plan, response: racedSuccess.response, accountant: accountant)
      return .degraded(degradationKind, usage: reconciledUsage(for: round))
    }

    if let cancellation = error as? ProviderInferenceCancellation {
      return .degraded(
        degradationKind,
        usage: conservativeUsage(
          for: plan,
          accountant: accountant,
          observedCompletionTokens: cancellation.observedCompletionTokens
        )
      )
    }

    if error is ProviderNoStartDeadline || error is CancellationError {
      return .degraded(degradationKind, usage: nil)
    }

    switch ProviderFailureAccounting.classify(error) {
    case .notStarted:
      return .degraded(degradationKind, usage: nil)
    case .mayHaveStarted(let observedCompletionTokens):
      return .degraded(
        degradationKind,
        usage: conservativeUsage(
          for: plan,
          accountant: accountant,
          observedCompletionTokens: observedCompletionTokens
        )
      )
    }
  }

  func classify(_ round: AnsweredRound) -> TurnResult {
    let usage = reconciledUsage(for: round)
    let response = round.response

    if !response.content.isEmpty {
      return .completed(
        content: response.content,
        usage: usage,
        providerState: response.providerState
      )
    }

    if response.finishReason == "length" {
      return .degraded(.outputTruncated, usage: usage)
    }

    return .degraded(.providerUnavailable, usage: usage)
  }

  /// The mid-dispatch wall-clock exit. The round's row is already recorded under this call id, so
  /// the conservative estimate is idempotent on it: the turn degrades without re-debiting the round.
  /// (The pre-send exit writes no row; a during-send deadline throws and takes the failure path.)
  func deadlineDegradation(_ round: AnsweredRound) -> TurnResult {
    .degraded(
      .providerUnavailable,
      usage: conservativeUsage(
        for: round.plan,
        accountant: round.accountant,
        observedCompletionTokens: 0
      )
    )
  }
}

// MARK: - Round Usage

extension AgentRuntime {
  /// The row an answered round owes: provider counts are truth, a missing count is estimated, and
  /// provider cost wins.
  func reconciledUsage(for round: AnsweredRound) -> ProviderUsage {
    round.accountant.reconciledRow(
      for: round.response,
      callID: round.plan.callID,
      context: round.plan.wire,
      tools: toolDefinitions,
      runID: round.plan.turn.scope.runID,
      sessionID: round.plan.turn.scope.sessionID
    )
  }

  /// The row a round owes when no authoritative usage came back: an estimated prompt plus the
  /// larger of the output reservation and any completion already observed.
  func conservativeUsage(
    for plan: RoundPlan,
    accountant: ProviderUsageAccountant,
    observedCompletionTokens: Int
  ) -> ProviderUsage {
    accountant.conservativeRow(
      callID: plan.callID,
      context: plan.wire,
      tools: toolDefinitions,
      observedCompletionTokens: observedCompletionTokens,
      runID: plan.turn.scope.runID,
      sessionID: plan.turn.scope.sessionID
    )
  }
}

// MARK: - Intermediate Usage

extension AgentRuntime {
  /// Records a tool-proposing round's usage as soon as the round returns; a final answer's row rides
  /// the gateway's commit instead. A full disk throws to the gateway, and any other write failure
  /// stops the turn before another provider call.
  func recordIntermediateUsage(
    _ round: AnsweredRound,
    ledger: inout RunSpendLedger,
    attempts: inout AttemptRuntimeState
  ) throws -> TurnStep<ProviderUsage> {
    let usage = reconciledUsage(for: round)
    do {
      try usageStore.recordUsage(usage)
    } catch StoreError.diskFull {
      throw StoreError.diskFull
    } catch {
      round.plan.turn.log.warning("mid-run usage write failed; halting provider calls: \(error)")
      return .exit(TurnExit(.degraded(.accountingFailed, usage: nil)))
    }

    ledger.record(usage)
    if round.response.usage == nil {
      attempts.recordMissingUsage(usage)
    }

    return .proceed(usage)
  }
}
