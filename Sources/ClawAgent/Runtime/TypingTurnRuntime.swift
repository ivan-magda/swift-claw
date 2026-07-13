import ClawCore
import Foundation

struct TypingTurnRuntime: Sendable {
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

  /// Races the provider call against the wall-clock deadline while pulsing the typing indicator.
  /// Returns the provider response if it wins, rethrows provider errors, and throws
  /// `AgentRuntime.DeadlineExceeded` if the deadline wins.
  func run(
    chatId: Int64,
    request: ChatRequest
  ) async throws -> ChatResponse {
    try await withTypingPulse(chatId: chatId, indicator: typingIndicator, clock: clock) {
      try await withThrowingTaskGroup(of: ChatResponse?.self) { group in
        defer { group.cancelAll() }

        group.addTask {
          try await provider.complete(request: request)
        }
        group.addTask {
          try await clock.sleep(for: .seconds(wallClockDeadlineSeconds))
          throw AgentRuntime.DeadlineExceeded()
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
}
