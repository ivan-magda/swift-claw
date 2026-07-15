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
