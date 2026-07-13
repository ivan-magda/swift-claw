/// Emits a Telegram "typing…" chat action for a chat. The action auto-expires (~5s) and has no
/// clear API, so the runtime re-issues it on an interval during a turn. The concrete impl
/// is Telegram-backed and injected by the gateway; tests use a recording mock.
public protocol TypingIndicator: Sendable {
  func sendTyping(chatId: Int64) async
}

public enum TypingIndicatorTiming {
  public static let reissueInterval: Duration = .seconds(4)
}

public func withTypingPulse<Result>(
  chatId: Int64,
  indicator: any TypingIndicator,
  clock: any Clock<Duration>,
  every interval: Duration = TypingIndicatorTiming.reissueInterval,
  operation: () async throws -> Result
) async rethrows -> Result {
  try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask {
      while !Task.isCancelled {
        await indicator.sendTyping(chatId: chatId)
        try? await clock.sleep(for: interval)
      }
    }

    defer {
      group.cancelAll()
    }

    return try await operation()
  }
}
