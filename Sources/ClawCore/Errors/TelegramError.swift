/// `conflict409` and `floodControl` are first-class so the poller can react distinctly
/// (loud-and-back-off vs. honor retry-after).
public enum TelegramError: Error, Sendable, Equatable {
  case conflict409(description: String)
  case floodControl(retryAfter: Int)
  case apiError(code: Int, description: String)
  case transport(String)
  case decoding(String)
}
