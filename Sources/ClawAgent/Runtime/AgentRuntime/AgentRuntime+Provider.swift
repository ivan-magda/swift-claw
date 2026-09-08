import ClawCore
import Foundation

// MARK: - Route Health

extension AgentRuntime {
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

extension AgentRuntime {
  /// One provider round-trip inside the SHARED wall-clock window: streaming when enabled,
  /// falling back to typing on a connect failure or a clean pre-stream rejection, else plain typing.
  /// `deadlineSeconds` is the REMAINING run budget, not a fresh 180 s. Throws the provider/deadline
  /// error; the loop maps it.
  func roundTrip(
    provider: any LLMProvider,
    target: TurnProgressTarget,
    request: ChatRequest,
    deadlineSeconds: Int
  ) async throws -> ChatResponse {
    guard streamingEnabled else {
      return try await runTypingTurn(
        provider: provider,
        target: target,
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
        target: target,
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
        target: target,
        request: request,
        deadlineSeconds: Self.remainingDeadlineSeconds(total: deadlineSeconds, since: streamStart)
      )
    }
  }
}

// MARK: - Transport Dispatch

private extension AgentRuntime {
  /// The wall-clock budget left for the buffered reattempt after the streaming attempt consumed part
  /// of the round's window. Floored at one second so `complete` still receives a positive bound even
  /// when the streaming attempt already exhausted the window.
  static func remainingDeadlineSeconds(total: Int, since start: ContinuousClock.Instant) -> Int {
    let elapsed = Int((ContinuousClock.now - start).components.seconds)
    return max(1, total - elapsed)
  }

  func runStreamingTurn(
    provider: any LLMProvider,
    target: TurnProgressTarget,
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
    return try await runtime.run(target: target, request: request)
  }

  func runTypingTurn(
    provider: any LLMProvider,
    target: TurnProgressTarget,
    request: ChatRequest,
    deadlineSeconds: Int
  ) async throws -> ChatResponse {
    let runtime = TypingTurnRuntime(
      provider: provider,
      typingIndicator: typingIndicator,
      wallClockDeadlineSeconds: deadlineSeconds,
      clock: clock
    )
    return try await runtime.run(target: target, request: request)
  }
}
