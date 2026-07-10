import ClawCore
import Foundation

struct TypingTurnRuntime: Sendable {
  /// How often the typing child re-issues the chat-action. Telegram's "typing..." auto-expires
  /// after about 5 seconds with no clear API, so we refresh just under that window.
  private static let typingReissueInterval: Duration = .seconds(4)

  private let provider: any LLMProvider
  private let typingIndicator: any TypingIndicator
  private let wallClockDeadlineSeconds: Int
  private let clock: any Clock<Duration>

  init(
    provider: any LLMProvider,
    typingIndicator: any TypingIndicator,
    wallClockDeadlineSeconds: Int,
    clock: any Clock<Duration>
  ) {
    self.provider = provider
    self.typingIndicator = typingIndicator
    self.wallClockDeadlineSeconds = wallClockDeadlineSeconds
    self.clock = clock
  }

  /// Races three children: the provider call, a typing loop re-issued every 4 seconds, and a
  /// deadline. Returns the provider response if it wins, rethrows provider errors, and throws
  /// `AgentRuntime.DeadlineExceeded` if the wall-clock deadline wins.
  func run(
    chatId: Int64,
    request: ChatRequest
  ) async throws -> ChatResponse {
    try await withThrowingTaskGroup(of: ChatResponse?.self) { group in
      defer { group.cancelAll() }

      group.addTask {
        try await provider.complete(request: request)
      }
      group.addTask {
        try await clock.sleep(for: .seconds(wallClockDeadlineSeconds))
        throw AgentRuntime.DeadlineExceeded()
      }
      group.addTask {
        while !Task.isCancelled {
          await typingIndicator.sendTyping(chatId: chatId)
          try await clock.sleep(for: Self.typingReissueInterval)
        }
        return nil
      }

      for try await outcome in group {
        if let response = outcome {
          return response
        }
      }

      throw AgentRuntime.DeadlineExceeded()
    }
  }
}
