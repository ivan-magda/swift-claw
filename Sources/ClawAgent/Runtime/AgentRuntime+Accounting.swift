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
  /// asked anyway. Both flow to the run-cancel path — the degradation reason stays
  /// `.providerUnavailable`, but a cancelled run's commit is arbitrated away, so no outage copy
  /// reaches the owner.
  ///
  /// `accountant` is the one bound to the route that made this call, so a failure is charged under
  /// the policies that call was actually issued with. `overrideKind` replaces the kind read from the
  /// error on the natural-failure path when the caller already knows the owner-facing reason;
  /// `nil` keeps the error's own kind.
  func failureOutcome(  // swiftlint:disable:this function_parameter_count
    _ error: any Error,
    callID: ProviderCallID,
    context: [ChatMessage],
    runId: Int64,
    sessionId: Int64,
    accountant: ProviderUsageAccountant,
    overrideKind: DegradationKind? = nil
  ) -> TurnResult {
    if let racedSuccess = error as? RacedDeadlineSuccess {
      // A real response landed alongside a won deadline: its usage is authoritative, so it is booked
      // through the same completed-call route a non-raced reply uses — never the conservative
      // estimate below — while the owner still sees the degraded timeout.
      return .degraded(
        .providerUnavailable,
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
        .providerUnavailable,
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
      return .degraded(.providerUnavailable, usage: nil)
    }

    // The vendor-neutral kind is read from the cause, the debit from the accounting disposition —
    // independently, so an auth/access/quota/replay rejection surfaces its own owner guidance while
    // an ambiguous transport loss stays the generic outage with a conservative row.
    let kind = overrideKind ?? Self.degradationKind(for: error)
    switch ProviderFailureAccounting.classify(error) {
    case .notStarted:
      return .degraded(kind, usage: nil)
    case .mayHaveStarted(let observedCompletionTokens):
      return .degraded(
        kind,
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

  /// The owner-facing degradation kind for a thrown provider failure, read from its vendor-neutral
  /// cause. Only the redaction-safe cases carry a distinct kind; the message-carrying causes
  /// (terminal / retryable / connect / rejected) and a non-provider error stay the generic outage,
  /// so no remote diagnostic text can ever reach owner copy through the kind.
  static func degradationKind(for error: any Error) -> DegradationKind {
    switch ProviderError.cause(of: error) {
    case .authenticationRequired:
      return .authenticationRequired
    case .accessDenied:
      return .accessDenied
    case .quotaLimited(let retryAfterSeconds):
      return .quotaLimited(retryAfterSeconds: retryAfterSeconds)
    case .invalidProviderState:
      return .invalidProviderState
    case .visionUnsupported:
      return .visionUnsupported
    case .credentialRefreshCompleted, .credentialRefreshExhausted, .credentialStateUnavailable:
      return .providerUnavailable
    case .terminal, .cleanRejection, .transportFailure, .retryable, .connectFailed, .rejected,
      .partialStreamWithoutCompletedTerminal, .localOutputLimit, .modelIdentityMismatch, .none:
      return .providerUnavailable
    }
  }

  static func attemptFailureCause(
    for error: any Error
  ) -> AttemptFailureCause? {
    let isDeadline =
      error is ProviderNoStartDeadline
      || error is RacedDeadlineSuccess
      || error is ProviderInferenceCancellation
    if isDeadline {
      return .deadline
    }
    if error is CancellationError {
      return .processInterruption
    }
    switch ProviderError.cause(of: error) {
    case .connectFailed, .transportFailure:
      return .transportFailure
    case .credentialRefreshCompleted:
      return .credentialRefreshCompleted
    case .credentialRefreshExhausted:
      return .credentialRefreshExhausted
    case .credentialStateUnavailable:
      return .credentialStateUnavailable
    case .partialStreamWithoutCompletedTerminal:
      return .partialStreamWithoutCompletedTerminal
    case .localOutputLimit:
      return .localOutputLimit
    case .modelIdentityMismatch:
      return .modelIdentityMismatch
    case .retryable, .quotaLimited, .authenticationRequired, .accessDenied,
      .invalidProviderState, .visionUnsupported, .terminal, .cleanRejection, .rejected, .none:
      return nil
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
