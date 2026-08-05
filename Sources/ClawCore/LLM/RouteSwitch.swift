/// How long the route that produced a failure should be left alone before it is probed again.
/// `long` is for causes that clear on a plan or account clock; `short` is for transport-shaped
/// failures that usually clear within a minute.
public enum RouteFailurePersistence: Sendable, Equatable {
  case short
  case long
}

// MARK: - Eligibility

extension ProviderError {
  /// The cooldown a route switch on this cause should arm, or `nil` when the cause must not switch
  /// routes at all.
  ///
  /// Two disjoint groups qualify. The nothing-was-generated rejections are the ones
  /// `ProviderFailureAccounting.classify` already reports as `notStarted`. The pre-stream head
  /// failures are the ones a streaming round already re-issues once on the buffered path — if
  /// re-sending to the same provider cannot double-charge, re-sending to a different one cannot
  /// either.
  ///
  /// `retryable` is excluded deliberately: the exchange may already owe tokens, which is also why
  /// the buffered reattempt refuses it.
  public var routeSwitchPersistence: RouteFailurePersistence? {
    switch self {
    case .quotaLimited, .authenticationRequired, .accessDenied:
      return .long
    case .connectFailed, .rejected:
      return .short
    case .retryable, .terminal, .cleanRejection, .invalidProviderState, .visionUnsupported:
      return nil
    }
  }

  /// Whether this cause may be re-issued against a different route.
  public var allowsRouteSwitch: Bool { routeSwitchPersistence != nil }
}

// MARK: - Decision

public enum RouteSwitch {
  /// The cooldown to arm for a thrown error, or `nil` when the turn must degrade instead of
  /// switching. A wrapped `ProviderFailure` carries the provider's own accounting verdict, and that
  /// verdict wins: a failure the provider tagged as possibly-started never switches, whatever its
  /// cause, because re-issuing it could double-charge and because deltas may already have reached
  /// the owner's draft. A bare `ProviderError`'s conservative `mayHaveStarted` classification is a
  /// billing default, not a provider verdict, so it does not veto here.
  public static func permits(_ error: any Error) -> RouteFailurePersistence? {
    guard let cause = ProviderError.cause(of: error) else { return nil }
    guard let persistence = cause.routeSwitchPersistence else { return nil }
    if let failure = error as? ProviderFailure, case .mayHaveStarted = failure.accounting {
      return nil
    }
    return persistence
  }

  /// The provider's own retry hint, so an armed cooldown can honor a bound longer than its tier
  /// default. Only a clean throttle carries one; every other cause leaves the tier to decide.
  /// Shared by the turn and schedule surfaces so both cooldown windows honor it identically.
  public static func retryAfterSeconds(of error: any Error) -> Int? {
    guard case .quotaLimited(let seconds)? = ProviderError.cause(of: error) else { return nil }
    return seconds
  }
}
