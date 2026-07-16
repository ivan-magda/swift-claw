import ClawCore
import Foundation

// MARK: - Result Classification

// Internal rather than `private` so the round-trip loop in `AgentRuntime.swift` can reach these; the
// stored collaborators they read are widened to `internal` there for the same reason.
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
  func failureOutcome(
    _ error: any Error,
    callID: ProviderCallID,
    context: [ChatMessage],
    runId: Int64,
    sessionId: Int64
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
          observedCompletionTokens: cancellation.observedCompletionTokens,
          runId: runId,
          sessionId: sessionId
        )
      )
    }
    if error is CancellationError {
      return .degraded(.providerUnavailable, usage: nil)
    }

    // The vendor-neutral kind is read from the cause, the debit from the accounting disposition —
    // independently, so an auth/access/quota/replay rejection surfaces its own owner guidance while
    // an ambiguous transport loss stays the generic outage with a conservative row.
    let kind = Self.degradationKind(for: error)
    switch Self.accounting(for: error) {
    case .notStarted:
      return .degraded(kind, usage: nil)
    case .mayHaveStarted(let observedCompletionTokens):
      return .degraded(
        kind,
        usage: accountant.conservativeRow(
          callID: callID,
          context: context,
          observedCompletionTokens: observedCompletionTokens,
          runId: runId,
          sessionId: sessionId
        )
      )
    }
  }

  /// The accounting disposition of a thrown error. Delegates to the one vendor-neutral reducer both
  /// the turn and schedule paths read, so a failure is charged the same way wherever it surfaces.
  static func accounting(for error: any Error) -> ProviderFailureAccounting {
    ProviderFailureAccounting.classify(error)
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
    case .terminal, .cleanRejection, .retryable, .connectFailed, .rejected, .none:
      return .providerUnavailable
    }
  }

  /// Maps a returned response to a result, debiting the reconciled usage (real, or estimated when
  /// the provider omits it): non-empty content → `.completed`; empty + `finishReason == "length"` →
  /// `.degraded(.outputTruncated)`; any other empty → `.degraded(.providerUnavailable)`. The row is
  /// minted through the shared accountant (provider cost wins), the same route an intermediate
  /// round-trip books through.
  func classify(
    response: ChatResponse,
    callID: ProviderCallID,
    context: [ChatMessage],
    runId: Int64,
    sessionId: Int64
  ) -> TurnResult {
    let usage = accountant.reconciledRow(
      for: response,
      callID: callID,
      context: context,
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
