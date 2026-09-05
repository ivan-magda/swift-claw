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

  /// Races the provider call against the wall-clock deadline while pulsing the typing indicator. The
  /// coordinator hands back a typed outcome — no loser discarded, both children drained — which maps
  /// to the return/throw contract the runtime's accounting reads: a response returns, a typed failure
  /// rethrows, and a won deadline throws the cancellation marker its disposition names.
  func run(
    target: TurnProgressTarget,
    request: ChatRequest
  ) async throws -> ChatResponse {
    try await withTypingPulse(
      chatId: target.chatId,
      messageThreadId: target.threadId,
      indicator: typingIndicator,
      clock: clock
    ) {
      let outcome = await ProviderDeadlineCoordinator.raceBuffered(
        deadlineSeconds: wallClockDeadlineSeconds,
        clock: clock,
        call: {
          do {
            return .response(try await provider.complete(request: request))
          } catch {
            return .failed(error)
          }
        }
      )

      switch outcome {
      case .response(let response):
        return response
      case .failed(let error):
        throw error
      case .timedOut(.notStarted):
        throw ProviderNoStartDeadline()
      case .timedOut(.mayHaveStarted(let observedCompletionTokens)):
        throw ProviderInferenceCancellation(observing: observedCompletionTokens)
      case .timedOut(.completed(let response)):
        // A response landed under the won deadline: still an owner-visible timeout, but the whole
        // response rides along so the runtime books its authoritative usage — real counts, provider
        // cost — instead of an estimate keyed only on the observed lower bound.
        throw RacedDeadlineSuccess(response: response)
      }
    }
  }
}
