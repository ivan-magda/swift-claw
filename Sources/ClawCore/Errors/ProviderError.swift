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
  case authenticationRequired
  case accessDenied
  case quotaLimited(retryAfterSeconds: Int?)
  case cleanRejection(status: Int)
  case invalidProviderState
  /// The route rejected the request because the configured model cannot look at images. Recognised
  /// from the rejection body, then reduced to this text-free case so the owner reply names the cause
  /// without quoting a remote diagnostic.
  case visionUnsupported
}

// MARK: - Redaction

extension ProviderError {
  /// Scrubs the quoted diagnostic a message-bearing cause carries, through the supplied redactor.
  /// The text-free cases carry no free text at all — that is exactly what makes them safe to surface
  /// — so they pass through unchanged. One home for the classification so the two wire adapters
  /// cannot disagree about which cases hold secret-bearing text.
  public func redacted(with redactor: SecretRedactor) -> ProviderError {
    switch self {
    case .connectFailed(let message):
      .connectFailed(message: redactor.redact(message))
    case .retryable(let status, let message):
      .retryable(status: status, message: redactor.redact(message))
    case .rejected(let status, let message):
      .rejected(status: status, message: redactor.redact(message))
    case .terminal(let status, let message):
      .terminal(status: status, message: redactor.redact(message))
    case .authenticationRequired,
      .accessDenied,
      .quotaLimited,
      .cleanRejection,
      .invalidProviderState,
      .visionUnsupported:
      self
    }
  }
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
      .invalidProviderState, .visionUnsupported:
      return .notStarted
    case .connectFailed, .retryable, .rejected:
      return .mayHaveStarted(observing: 0)
    }
  }
}
