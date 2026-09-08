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
  func failureOutcome(  // swiftlint:disable:this function_parameter_count
    _ error: any Error,
    callID: ProviderCallID,
    context: [ChatMessage],
    runId: Int64,
    sessionId: Int64,
    accountant: ProviderUsageAccountant,
    degradationKind: DegradationKind
  ) -> TurnResult {
    if let racedSuccess = error as? RacedDeadlineSuccess {
      // A real response landed alongside a won deadline: its usage is authoritative
      return .degraded(
        degradationKind,
        usage: accountant.reconciledRow(
          for: racedSuccess.response,
          callID: callID,
          context: context,
          tools: toolDefinitions,
          runId: runId,
          sessionId: sessionId
        )
      )
    }

    if let cancellation = error as? ProviderInferenceCancellation {
      return .degraded(
        degradationKind,
        usage: accountant.conservativeRow(
          callID: callID,
          context: context,
          tools: toolDefinitions,
          observedCompletionTokens: cancellation.observedCompletionTokens,
          runId: runId,
          sessionId: sessionId
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
        usage: accountant.conservativeRow(
          callID: callID,
          context: context,
          tools: toolDefinitions,
          observedCompletionTokens: observedCompletionTokens,
          runId: runId,
          sessionId: sessionId
        )
      )
    }
  }

  /// Maps a returned response to a result, debiting the reconciled usage (real, or estimated when
  /// the provider omits it): non-empty content → `.completed`; empty + `finishReason == "length"` →
  /// `.degraded(.outputTruncated)`; any other empty → `.degraded(.providerUnavailable)`. The row is
  /// minted through the passed accountant (provider cost wins), the same route an intermediate
  /// round-trip books through — that accountant belongs to the route that produced this response.
  func classify(  // swiftlint:disable:this function_parameter_count
    response: ChatResponse,
    callID: ProviderCallID,
    context: [ChatMessage],
    runId: Int64,
    sessionId: Int64,
    accountant: ProviderUsageAccountant
  ) -> TurnResult {
    let usage = accountant.reconciledRow(
      for: response,
      callID: callID,
      context: context,
      tools: toolDefinitions,
      runId: runId,
      sessionId: sessionId
    )

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
}
