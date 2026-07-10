/// Provider failures tagged for the retry classifier and the degradation UX.
/// retryable = 408 / 429 / 5xx (incl. 529) mid-exchange or transport; terminal = 400 / 401 / 403 /
/// 404 / 413 / 422; rejected = a retryable-class status on the STREAM RESPONSE HEAD before any SSE
/// bytes — the server answered with an error and generated nothing, so a re-issue is
/// double-charge-safe (unlike `.retryable` from a stream, where generation may have started).
public enum ProviderError: Error, Sendable, Equatable {
  case connectFailed(message: String)
  case retryable(status: Int?, message: String)
  case rejected(status: Int, message: String)
  case terminal(status: Int?, message: String)
}
