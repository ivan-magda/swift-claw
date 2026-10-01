/// Per-chat send deadlines from Telegram flood control (`retry_after`). A hold only ever extends,
/// and an elapsed one is dropped on the next check, so the map stays the size of the chats still
/// throttled.
public struct FloodControlDeadlines<Instant: InstantProtocol>: Sendable {
  private var notBefore: [Int64: Instant] = [:]

  public init() {}

  /// Whether `chatID` is still held at `now`.
  public mutating func isHeld(_ chatID: Int64, at now: Instant) -> Bool {
    guard let deadline = notBefore[chatID] else {
      return false
    }

    if now < deadline {
      return true
    }
    notBefore[chatID] = nil

    return false
  }

  /// Holds `chatID` until `deadline`, keeping a later deadline already in place.
  public mutating func hold(_ chatID: Int64, until deadline: Instant) {
    notBefore[chatID] = max(notBefore[chatID] ?? deadline, deadline)
  }
}
