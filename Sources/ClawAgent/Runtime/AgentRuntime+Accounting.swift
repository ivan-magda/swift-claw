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
        usage: usageRow(
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
        usage: conservativeDebit(
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

    switch Self.accounting(for: error) {
    case .notStarted:
      return .degraded(.providerUnavailable, usage: nil)
    case .mayHaveStarted(let observedCompletionTokens):
      return .degraded(
        .providerUnavailable,
        usage: conservativeDebit(
          callID: callID,
          context: context,
          observedCompletionTokens: observedCompletionTokens,
          runId: runId,
          sessionId: sessionId
        )
      )
    }
  }

  /// The accounting disposition of a thrown error. A `ProviderFailure` carries the provider's own
  /// verdict; a bare `ProviderError` (the legacy Chat Completions seam, which mints no wrapper) is
  /// mapped by cause class — a recognized head rejection proves no start, everything else may have.
  /// An unrecognized error means a body was already handed off, so it too may have started.
  static func accounting(for error: any Error) -> ProviderFailureAccounting {
    if let failure = error as? ProviderFailure {
      return failure.accounting
    }
    guard let providerError = error as? ProviderError else {
      return .mayHaveStarted(observing: 0)
    }
    switch providerError {
    case .terminal, .authenticationRequired, .accessDenied, .quotaLimited, .cleanRejection,
      .invalidProviderState:
      return .notStarted
    case .connectFailed, .retryable, .rejected:
      return .mayHaveStarted(observing: 0)
    }
  }

  /// Maps a returned response to a result, debiting the reconciled usage (real, or estimated when
  /// the provider omits it): non-empty content → `.completed`; empty + `finishReason == "length"` →
  /// `.degraded(.outputTruncated)`; any other empty → `.degraded(.providerUnavailable)`. Cost is
  /// resolved via `costResolver` (provider cost wins) into the `ProviderUsage` row.
  func classify(
    response: ChatResponse,
    callID: ProviderCallID,
    context: [ChatMessage],
    runId: Int64,
    sessionId: Int64
  ) -> TurnResult {
    let resolvedUsage = reservedUsage(for: response, context: context)
    let resolvedCost = costResolver.resolve(
      model: configuredReference,
      usage: resolvedUsage.usage,
      providerCost: response.costFromProvider,
      policy: costPolicy
    )
    let usage = ProviderUsage(
      providerCallID: callID,
      runId: runId,
      sessionId: sessionId,
      model: configuredReference,
      usage: resolvedUsage,
      cost: resolvedCost,
      ts: Date()
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

  /// The reconciled usage row for a response that carries authoritative usage — an intermediate
  /// round-trip, or a reply that landed alongside a won deadline. Same resolution as `classify`
  /// (provider counts untouched, provider cost wins), without the terminal classification, so every
  /// completed-call row is booked through one route rather than a second, estimated one.
  func usageRow(
    for response: ChatResponse,
    callID: ProviderCallID,
    context: [ChatMessage],
    runId: Int64,
    sessionId: Int64
  ) -> ProviderUsage {
    let resolvedUsage = reservedUsage(for: response, context: context)
    let resolvedCost = costResolver.resolve(
      model: configuredReference,
      usage: resolvedUsage.usage,
      providerCost: response.costFromProvider,
      policy: costPolicy
    )

    return ProviderUsage(
      providerCallID: callID,
      runId: runId,
      sessionId: sessionId,
      model: configuredReference,
      usage: resolvedUsage,
      cost: resolvedCost,
      ts: Date()
    )
  }

  /// Reconciled usage with the replay-state reservation folded into an *estimated* prompt only.
  /// Provider-returned counts are authoritative and stay untouched; a missing count is estimated,
  /// and there the reservation is added so a state-carrying wire is never under-accounted.
  func reservedUsage(for response: ChatResponse, context: [ChatMessage]) -> ResolvedUsage {
    withReservation(usageResolver.resolve(response: response, context: context), context: context)
  }

  /// Adds the reservation to an estimated prompt; leaves provider-returned usage alone.
  func withReservation(_ base: ResolvedUsage, context: [ChatMessage]) -> ResolvedUsage {
    guard base.isEstimated else {
      return base
    }
    let reservation = reservationPolicy.additionalTokens(for: context)
    guard reservation > 0 else {
      return base
    }
    let promptTokens = base.usage.promptTokens + reservation
    return ResolvedUsage(
      usage: ChatUsage(
        promptTokens: promptTokens,
        completionTokens: base.usage.completionTokens,
        totalTokens: promptTokens + base.usage.completionTokens
      ),
      isEstimated: true
    )
  }

  /// The conservative `ProviderUsage` for a call with no authoritative usage — a deadline, an
  /// exhausted retry, an ambiguous failure, or a cancellation that may have generated tokens.
  /// Prompt is estimated from context plus the replay-state reservation; completion is the larger
  /// of the local output reservation and any count production code observed, so a partial reply
  /// already seen is never under-charged. No provider cost exists for a call that never reconciled,
  /// so cost comes from the best-effort tier (floored, never a silent $0) — or a confirmed zero
  /// under `includedPlan`. The row is an estimate.
  func conservativeDebit(
    callID: ProviderCallID,
    context: [ChatMessage],
    observedCompletionTokens: Int,
    runId: Int64,
    sessionId: Int64
  ) -> ProviderUsage {
    let promptTokens =
      TokenEstimator.estimateInputTokens(context) + reservationPolicy.additionalTokens(for: context)
    let completionTokens = max(budget.maxOutputTokens, observedCompletionTokens)
    let resolvedUsage = ResolvedUsage(
      usage: ChatUsage(
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        totalTokens: promptTokens + completionTokens
      ),
      isEstimated: true
    )
    let resolvedCost = costResolver.resolve(
      model: configuredReference,
      usage: resolvedUsage.usage,
      providerCost: nil,
      policy: costPolicy
    )

    return ProviderUsage(
      providerCallID: callID,
      runId: runId,
      sessionId: sessionId,
      model: configuredReference,
      usage: resolvedUsage,
      cost: resolvedCost,
      ts: Date()
    )
  }
}
