/// Emits a Telegram "typing…" chat action for a chat. The action auto-expires (~5s) and has no
/// clear API, so the runtime re-issues it on an interval during a turn. The concrete impl
/// is Telegram-backed and injected by the gateway; tests use a recording mock.
public protocol TypingIndicator: Sendable {
  /// `messageThreadID` is the forum topic the pulse belongs to; absent in a DM, where the whole
  /// chat is the destination.
  func sendTyping(chatID: Int64, messageThreadID: Int64?) async
}

extension TypingIndicator {
  /// The whole-chat spelling every DM pulse and every callerless notice uses.
  public func sendTyping(chatID: Int64) async {
    await sendTyping(chatID: chatID, messageThreadID: nil)
  }
}

public enum TypingIndicatorTiming {
  public static let reissueInterval: Duration = .seconds(4)
}

public func withTypingPulse<Result>(
  chatID: Int64,
  messageThreadID: Int64? = nil,
  indicator: any TypingIndicator,
  clock: any Clock<Duration>,
  every interval: Duration = TypingIndicatorTiming.reissueInterval,
  operation: () async throws -> Result
) async rethrows -> Result {
  try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask {
      while !Task.isCancelled {
        await indicator.sendTyping(chatID: chatID, messageThreadID: messageThreadID)
        try? await clock.sleep(for: interval)
      }
    }

    defer { group.cancelAll() }

    return try await operation()
  }
}
