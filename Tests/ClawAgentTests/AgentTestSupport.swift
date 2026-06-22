import Foundation
import Testing

@testable import ClawAgent
@testable import ClawCore

// MARK: - Test doubles

/// Counts typing pulses so "issued at least once" and "never issued" are both observable.
actor RecordingTyping: TypingIndicator {
  private(set) var calls = 0

  func sendTyping(chatId: Int64) async {
    calls += 1
  }
}

/// Returns a scripted response or throws a scripted `ProviderError`;
/// records its call count so the preflight-stop path can assert the provider was never reached.
actor StubProvider: LLMProvider {
  enum Outcome: Sendable {
    case respond(ChatResponse)
    case fail(ProviderError)
  }

  private let outcome: Outcome
  private(set) var calls = 0

  init(_ outcome: Outcome) {
    self.outcome = outcome
  }

  func complete(request: ChatRequest) async throws -> ChatResponse {
    calls += 1
    switch outcome {
    case .respond(let response): return response
    case .fail(let error): throw error
    }
  }
}

/// Never returns within the deadline: sleeps an hour so the injected no-op `sleep` lets the
/// wall-clock deadline win the race deterministically.
actor HangingProvider: LLMProvider {
  private(set) var calls = 0

  func complete(request: ChatRequest) async throws -> ChatResponse {
    calls += 1
    try await Task.sleep(for: .seconds(3600))
    return ChatResponse(content: "late", finishReason: "stop", usage: .zero, costFromProvider: nil)
  }
}

// MARK: - Builders

/// A real sleep honoring the requested duration — the default so an instant provider wins the
/// race and the deadline never fires. The deadline test overrides it with `{ _ in }`.
let realSleep: @Sendable (Duration) async throws -> Void = { duration in
  try await Task.sleep(for: duration)
}

func makeCostResolver(
  priceTable: PriceTable = .empty,
  referenceUSDPerToken: Double = RunBudget.default.referenceUSDPerToken
) -> CostResolver {
  CostResolver(priceTable: priceTable, referenceUSDPerToken: referenceUSDPerToken)
}

func makeRuntime(
  provider: any LLMProvider,
  typing: any TypingIndicator = RecordingTyping(),
  costResolver: CostResolver = makeCostResolver(),
  budget: RunBudget = .default,
  model: String = "gpt-4o",
  sleep: @escaping @Sendable (Duration) async throws -> Void = realSleep
) -> AgentRuntime {
  AgentRuntime(
    provider: provider,
    typingIndicator: typing,
    costResolver: costResolver,
    budget: budget,
    model: model,
    sleep: sleep
  )
}

func userMessage(_ content: String) -> StoredMessage {
  StoredMessage(role: .user, content: content, provenance: .trusted)
}

func okResponse(
  content: String = "Hello there",
  finishReason: String = "stop",
  usage: ChatUsage = ChatUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15),
  costFromProvider: Double? = 0.0021
) -> ChatResponse {
  ChatResponse(
    content: content,
    finishReason: finishReason,
    usage: usage,
    costFromProvider: costFromProvider
  )
}
