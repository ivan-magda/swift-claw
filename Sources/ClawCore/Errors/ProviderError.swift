/// Provider failures tagged for the retry classifier and the degradation UX.
/// retryable = 408 / 429 / 5xx (incl. 529) mid-exchange or transport; terminal = 400 / 401 / 403 /
/// 404 / 413 / 422; rejected = a retryable-class status on the STREAM RESPONSE HEAD before any SSE
/// bytes — the server answered with an error and generated nothing, so a re-issue is
/// double-charge-safe (unlike `.retryable` from a stream, where generation may have started).
///
/// The message-carrying cases quote a provider diagnostic, so whoever builds one owes it a
/// redaction pass. The cases below carry no free text at all: the status or the case name is the
/// whole fact, which is what makes them safe to surface without one.
public enum ProviderError: Error, Sendable, Equatable {
  case connectFailed(message: String)
  case retryable(status: Int?, message: String)
  case rejected(status: Int, message: String)
  case terminal(status: Int?, message: String)
  /// The credential is missing, expired beyond refresh, or refused twice. The owner must log in
  /// again; no further request will succeed until they do.
  case authenticationRequired
  /// The credential is valid but not entitled to this call. Refreshing it would change nothing, so
  /// this must never be answered with a re-login prompt.
  case accessDenied
  /// A clean throttle. The credential stays valid; `retryAfterSeconds` is the server's bounded hint
  /// when it gave one.
  case quotaLimited(retryAfterSeconds: Int?)
  /// A non-success response head reached before any inference began, so nothing was generated.
  case cleanRejection(status: Int)
  /// Replay state the route would not accept. The turn can be re-issued without it.
  case invalidProviderState
}

// MARK: - Vendor-neutral failure reading

extension ProviderError {
  /// The vendor-neutral cause of a thrown error, unwrapping a `ProviderFailure`. Both execution
  /// methods surface the same causes — a bare `ProviderError` from the Chat Completions seam, or one
  /// wrapped in a `ProviderFailure` by the managed route — so the turn and schedule paths read the
  /// cause identically regardless of which threw. `nil` for a non-provider error: a body was already
  /// handed off to produce it, so the caller treats it as ambiguous.
  public static func cause(of error: any Error) -> ProviderError? {
    if let failure = error as? ProviderFailure {
      return failure.cause
    }
    return error as? ProviderError
  }
}

extension ProviderFailureAccounting {
  /// The accounting disposition of a thrown error, read identically on every surface so the turn and
  /// schedule paths debit the same way. A `ProviderFailure` carries the provider's own verdict; a
  /// bare `ProviderError` is mapped by cause class — a recognized head rejection (auth, access,
  /// quota, clean rejection, replay state, terminal 4xx) proves nothing was generated, everything
  /// else may have. An unrecognized error means a body was already handed off, so it too may have
  /// started.
  public static func classify(_ error: any Error) -> ProviderFailureAccounting {
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
}
