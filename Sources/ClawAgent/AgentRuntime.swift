import ClawCore
import Foundation

/// Why a turn produced no usable answer. Maps to a plain-language degradation reply (§7); the
/// stable `rawValue` is what the audit log records, so it survives case renames.
public enum DegradationKind: String, Sendable, Equatable {
  case providerUnavailable
  case outputTruncated
}

/// The outcome of one orchestrated turn. `runTurn` never throws — every failure becomes one of
/// these so the gateway always has something to persist and send (never silence).
public enum TurnResult: Sendable, Equatable {
  /// A usable answer plus the reconciled, provider-truth usage to debit.
  case completed(content: String, usage: ProviderUsage)
  /// No usable answer. `usage` is the real row when the call returned (truncation) or an
  /// estimated row when it didn't (deadline / exhausted retries); `nil` for terminal errors.
  case degraded(DegradationKind, usage: ProviderUsage?)
  /// The offline budget gate refused before any provider call; `cap` names the tripped limit.
  case budgetStopped(cap: String)
}

/// The pure orchestration of one blocking turn: preflight → typing + wall-clock deadline →
/// provider call → classify. No persistence or sending (the gateway owns that in Task 5); all
/// collaborators are injected `ClawCore` protocols so tests drive it with mocks.
public struct AgentRuntime: Sendable {
  private let provider: any LLMProvider
  private let typingIndicator: any TypingIndicator
  private let costResolver: CostResolver
  private let budget: RunBudget
  private let model: String
  /// Injected so tests can make the deadline fire instantly with a no-op sleep.
  private let sleep: @Sendable (Duration) async throws -> Void

  public init(
    provider: any LLMProvider,
    typingIndicator: any TypingIndicator,
    costResolver: CostResolver,
    budget: RunBudget,
    model: String,
    sleep: @escaping @Sendable (Duration) async throws -> Void
  ) {
    self.provider = provider
    self.typingIndicator = typingIndicator
    self.costResolver = costResolver
    self.budget = budget
    self.model = model
    self.sleep = sleep
  }

  // swiftlint:disable:next function_parameter_count
  public func runTurn(
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    context: [ChatMessage],
    todayTokens: Int,
    todayUSD: Double
  ) async -> TurnResult {
    let estimate = TokenEstimator.estimateTotalTokens(context, maxOutput: budget.maxOutputTokens)
    let estimatedCost = costResolver.resolve(
      model: model,
      usage: ChatUsage(promptTokens: estimate, completionTokens: 0, totalTokens: estimate),
      providerCost: nil
    ).costUSD
    let gate = BudgetGate(budget: budget)

    if case .deny(let cap) = gate.preflight(
      todayTokens: todayTokens,
      todayUSD: todayUSD,
      estimatedTotalTokens: estimate,
      estimatedCostUSD: estimatedCost
    ) {
      return .budgetStopped(cap: cap)
    }

    let request = ChatRequest(
      model: model,
      messages: context,
      maxOutputTokens: budget.maxOutputTokens
    )

    do {
      let response = try await withTypingAndDeadline(chatId: chatId, request: request)
      return classify(response: response, runId: runId, sessionId: sessionId)
    } catch let error as ProviderError {
      switch error {
      case .terminal:
        // No retries burned, no usage produced → degrade without a debit.
        return .degraded(.providerUnavailable, usage: nil)
      case .retryable:
        // Retries were exhausted (F28): debit the pre-call estimate so a flapper can't run free.
        return .degraded(
          .providerUnavailable,
          usage: estimatedDebit(context: context, runId: runId, sessionId: sessionId)
        )
      }
    } catch {
      // DeadlineExceeded / cancellation: the call never produced usage → debit the estimate.
      return .degraded(
        .providerUnavailable,
        usage: estimatedDebit(context: context, runId: runId, sessionId: sessionId)
      )
    }
  }

  // MARK: - Load-bearing

  /// Marker error thrown by the deadline child of `withTypingAndDeadline` when the wall-clock
  /// window elapses; the `runTurn` shell maps it to the estimated-debit degradation path.
  struct DeadlineExceeded: Error {}

  /// How often the typing child re-issues the chat-action. Telegram's "typing…" auto-expires
  /// after ~5s with no clear API (F5), so we refresh just under that window.
  private static let typingReissueInterval: Duration = .seconds(4)

  /// Races three children: the provider call, a typing loop re-issued every 4s, and a deadline
  /// (`sleep(.seconds(budget.wallClockDeadlineSeconds))` then `throw DeadlineExceeded`). Returns
  /// the provider response if it wins; rethrows its `ProviderError`; throws `DeadlineExceeded` if
  /// the deadline wins. `defer { cancelAll }` must stop typing on every exit (F5). The typing loop
  /// observes `Task.isCancelled` after `sendTyping` to avoid tight-spinning under a no-op sleep.
  private func withTypingAndDeadline(
    chatId: Int64,
    request: ChatRequest
  ) async throws -> ChatResponse {
    try await withThrowingTaskGroup(of: ChatResponse?.self) { group in
      defer { group.cancelAll() }

      group.addTask {
        try await provider.complete(request: request)
      }
      group.addTask {
        try await sleep(.seconds(budget.wallClockDeadlineSeconds))
        throw DeadlineExceeded()
      }
      group.addTask {
        while !Task.isCancelled {
          await typingIndicator.sendTyping(chatId: chatId)
          try await sleep(Self.typingReissueInterval)
        }
        return nil
      }

      for try await outcome in group {
        if let response = outcome {
          return response
        }
      }

      throw DeadlineExceeded()
    }
  }

  /// Maps a returned response to a result, debiting the real usage: non-empty content →
  /// `.completed`; empty + `finishReason == "length"` → `.degraded(.outputTruncated)`; any other
  /// empty → `.degraded(.providerUnavailable)`. Cost is resolved via `costResolver` (provider cost
  /// wins) into the `ProviderUsage` row.
  private func classify(
    response: ChatResponse,
    runId: Int64,
    sessionId: Int64
  ) -> TurnResult {
    let resolvedCost = costResolver.resolve(
      model: model,
      usage: response.usage,
      providerCost: response.costFromProvider
    )
    let usage = ProviderUsage(
      runId: runId,
      sessionId: sessionId,
      model: model,
      promptTokens: response.usage.promptTokens,
      completionTokens: response.usage.completionTokens,
      costUSD: resolvedCost.costUSD,
      costSource: resolvedCost.source,
      isEstimated: resolvedCost.isEstimated,
      ts: Date()
    )

    if !response.content.isEmpty {
      return .completed(content: response.content, usage: usage)
    }

    if response.finishReason == "length" {
      return .degraded(.outputTruncated, usage: usage)
    }

    return .degraded(.providerUnavailable, usage: usage)
  }

  /// The pre-call estimated `ProviderUsage` debited when no real usage exists (deadline /
  /// exhausted retries): `promptTokens` = estimated input tokens, `completionTokens` =
  /// `budget.maxOutputTokens`, cost via the heuristic tier, `isEstimated = true`.
  private func estimatedDebit(
    context: [ChatMessage],
    runId: Int64,
    sessionId: Int64
  ) -> ProviderUsage {
    let promptTokens = TokenEstimator.estimateInputTokens(context)
    let completionTokens = budget.maxOutputTokens
    let estimatedUsage = ChatUsage(
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      totalTokens: promptTokens + completionTokens
    )
    // No provider cost exists for a call that never returned → the resolver's best-effort tier
    // carries USD (floored, never a silent $0 — D1/F19). The row is an estimate regardless.
    let resolvedCost = costResolver.resolve(model: model, usage: estimatedUsage, providerCost: nil)

    return ProviderUsage(
      runId: runId,
      sessionId: sessionId,
      model: model,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      costUSD: resolvedCost.costUSD,
      costSource: resolvedCost.source,
      isEstimated: true,
      ts: Date()
    )
  }
}
