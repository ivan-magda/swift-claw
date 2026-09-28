import ClawCore
import Foundation

// MARK: - Result Classification

// Internal rather than `private` so the round-trip loop in `AgentRuntime.swift` can reach these.
// They take the accountant rather than reading one off the runtime, so each call is charged under
// the policies of the route that issued it.
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

  /// Maps an answered round to a result, debiting its reconciled usage (real, or estimated when
  /// the provider omits it): non-empty content → `.completed`; empty + `finishReason == "length"` →
  /// `.degraded(.outputTruncated)`; any other empty → `.degraded(.providerUnavailable)`.
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

  /// The mid-dispatch wall-clock exit. The round's provider call already returned and its
  /// intermediate row was recorded under this same call id, so the conservative estimate this books
  /// is idempotent on that identity: it degrades the turn without re-debiting the round. The other
  /// two exits account differently: the pre-send exit writes no row (the call provably never
  /// issued), and a deadline that wins during the send surfaces as a thrown cancellation marker the
  /// generic failure path classifies by its accounting disposition.
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
