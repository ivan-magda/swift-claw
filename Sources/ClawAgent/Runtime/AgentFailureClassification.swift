import ClawCore

struct AgentFailureClassification {
  let degradationKind: DegradationKind
  let attemptFailureCause: AttemptFailureCause?

  init(error: any Error) {
    let isDeadline =
      error is ProviderNoStartDeadline
      || error is RacedDeadlineSuccess
      || error is ProviderInferenceCancellation
    if isDeadline {
      self = Self.unavailable(failureCause: .deadline)
      return
    }

    if error is CancellationError {
      self = Self.unavailable(failureCause: .processInterruption)
      return
    }

    guard let providerCause = ProviderError.cause(of: error) else {
      self = Self.unavailable()
      return
    }

    self = Self.classify(providerCause)
  }

  private init(
    degradationKind: DegradationKind,
    attemptFailureCause: AttemptFailureCause?
  ) {
    self.degradationKind = degradationKind
    self.attemptFailureCause = attemptFailureCause
  }
}

// MARK: - Provider Errors

private extension AgentFailureClassification {
  // Exhaustiveness ensures every new provider cause chooses both agent-facing projections.
  static func classify(  // swiftlint:disable:this cyclomatic_complexity
    _ cause: ProviderError
  ) -> Self {
    switch cause {
    case .connectFailed, .transportFailure:
      unavailable(failureCause: .transportFailure)
    case .retryable, .rejected, .terminal, .cleanRejection:
      unavailable()
    case .authenticationRequired:
      Self(
        degradationKind: .authenticationRequired,
        attemptFailureCause: nil
      )
    case .accessDenied:
      Self(
        degradationKind: .accessDenied,
        attemptFailureCause: nil
      )
    case .quotaLimited(let retryAfterSeconds):
      Self(
        degradationKind: .quotaLimited(retryAfterSeconds: retryAfterSeconds),
        attemptFailureCause: nil
      )
    case .invalidProviderState:
      Self(
        degradationKind: .invalidProviderState,
        attemptFailureCause: nil
      )
    case .visionUnsupported:
      Self(
        degradationKind: .visionUnsupported,
        attemptFailureCause: nil
      )
    case .credentialRefreshCompleted:
      unavailable(failureCause: .credentialRefreshCompleted)
    case .credentialRefreshExhausted:
      unavailable(failureCause: .credentialRefreshExhausted)
    case .credentialStateUnavailable:
      unavailable(failureCause: .credentialStateUnavailable)
    case .partialStreamWithoutCompletedTerminal:
      unavailable(failureCause: .partialStreamWithoutCompletedTerminal)
    case .localOutputLimit:
      unavailable(failureCause: .localOutputLimit)
    case .modelIdentityMismatch:
      unavailable(failureCause: .modelIdentityMismatch)
    }
  }

  static func unavailable(
    failureCause: AttemptFailureCause? = nil
  ) -> Self {
    Self(
      degradationKind: .providerUnavailable,
      attemptFailureCause: failureCause
    )
  }
}
