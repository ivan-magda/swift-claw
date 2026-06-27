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
  private let draftStreamer: any RichDraftStreaming
  private let streamingEnabled: Bool
  private let costResolver: CostResolver
  private let usageResolver: UsageResolver
  private let budget: RunBudget
  private let model: String
  /// Injected so tests can make the deadline fire instantly with a no-op sleep.
  private let sleep: @Sendable (Duration) async throws -> Void

  public init(
    provider: any LLMProvider,
    typingIndicator: any TypingIndicator,
    draftStreamer: any RichDraftStreaming,
    streamingEnabled: Bool,
    costResolver: CostResolver,
    usageResolver: UsageResolver = UsageResolver(),
    budget: RunBudget,
    model: String,
    sleep: @escaping @Sendable (Duration) async throws -> Void
  ) {
    self.provider = provider
    self.typingIndicator = typingIndicator
    self.draftStreamer = draftStreamer
    self.streamingEnabled = streamingEnabled
    self.costResolver = costResolver
    self.usageResolver = usageResolver
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
    let inputTokens = TokenEstimator.estimateInputTokens(context)
    let estimate = inputTokens + budget.maxOutputTokens
    let estimatedCost = costResolver.resolve(
      model: model,
      usage: ChatUsage(
        promptTokens: inputTokens,
        completionTokens: budget.maxOutputTokens,
        totalTokens: estimate
      ),
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

    if streamingEnabled {
      do {
        let response = try await runStreamingTurn(
          chatId: chatId,
          draftId: runId,
          request: request
        )
        return classify(response: response, context: context, runId: runId, sessionId: sessionId)
      } catch ProviderError.connectFailed {
        do {
          let response = try await runTypingTurn(chatId: chatId, request: request)
          return classify(response: response, context: context, runId: runId, sessionId: sessionId)
        } catch {
          return degradedForCaughtError(error, context: context, runId: runId, sessionId: sessionId)
        }
      } catch {
        return degradedForStreamingError(
          error,
          context: context,
          runId: runId,
          sessionId: sessionId
        )
      }
    } else {
      do {
        let response = try await runTypingTurn(chatId: chatId, request: request)
        return classify(response: response, context: context, runId: runId, sessionId: sessionId)
      } catch {
        return degradedForCaughtError(error, context: context, runId: runId, sessionId: sessionId)
      }
    }
  }

  // MARK: - Load-bearing

  /// Marker error thrown by turn-runtime deadline children when the wall-clock window elapses; the
  /// `runTurn` shell maps it to the estimated-debit degradation path.
  struct DeadlineExceeded: Error {}

  private func runStreamingTurn(
    chatId: Int64,
    draftId: Int64,
    request: ChatRequest
  ) async throws -> ChatResponse {
    let runtime = StreamingTurnRuntime(
      provider: provider,
      typingIndicator: typingIndicator,
      draftStreamer: draftStreamer,
      wallClockDeadlineSeconds: budget.wallClockDeadlineSeconds,
      sleep: sleep
    )
    return try await runtime.run(
      chatId: chatId,
      draftId: draftId,
      request: request
    )
  }

  private func runTypingTurn(
    chatId: Int64,
    request: ChatRequest
  ) async throws -> ChatResponse {
    let runtime = TypingTurnRuntime(
      provider: provider,
      typingIndicator: typingIndicator,
      wallClockDeadlineSeconds: budget.wallClockDeadlineSeconds,
      sleep: sleep
    )
    return try await runtime.run(chatId: chatId, request: request)
  }

  private func degradedForCaughtError(
    _ error: any Error,
    context: [ChatMessage],
    runId: Int64,
    sessionId: Int64
  ) -> TurnResult {
    if let providerError = error as? ProviderError {
      switch providerError {
      case .connectFailed, .retryable:
        return .degraded(
          .providerUnavailable,
          usage: estimatedDebit(context: context, runId: runId, sessionId: sessionId)
        )
      case .terminal:
        return .degraded(.providerUnavailable, usage: nil)
      }
    }

    return .degraded(
      .providerUnavailable,
      usage: estimatedDebit(context: context, runId: runId, sessionId: sessionId)
    )
  }

  private func degradedForStreamingError(
    _ error: any Error,
    context: [ChatMessage],
    runId: Int64,
    sessionId: Int64
  ) -> TurnResult {
    if let providerError = error as? ProviderError {
      switch providerError {
      case .connectFailed, .retryable, .terminal:
        return .degraded(
          .providerUnavailable,
          usage: estimatedDebit(context: context, runId: runId, sessionId: sessionId)
        )
      }
    }

    return .degraded(
      .providerUnavailable,
      usage: estimatedDebit(context: context, runId: runId, sessionId: sessionId)
    )
  }

  /// Maps a returned response to a result, debiting the reconciled usage (real, or estimated when
  /// the provider omits it): non-empty content → `.completed`; empty + `finishReason == "length"` →
  /// `.degraded(.outputTruncated)`; any other empty → `.degraded(.providerUnavailable)`. Cost is
  /// resolved via `costResolver` (provider cost wins) into the `ProviderUsage` row.
  private func classify(
    response: ChatResponse,
    context: [ChatMessage],
    runId: Int64,
    sessionId: Int64
  ) -> TurnResult {
    let resolvedUsage = usageResolver.resolve(response: response, context: context)
    let resolvedCost = costResolver.resolve(
      model: model,
      usage: resolvedUsage.usage,
      providerCost: response.costFromProvider
    )
    let usage = ProviderUsage(
      runId: runId,
      sessionId: sessionId,
      model: model,
      usage: resolvedUsage,
      cost: resolvedCost,
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
  /// exhausted retries): prompt from context, completion reserved at the output cap, cost via the
  /// best-effort tier. No provider cost exists for a call that never returned, so the resolver's
  /// heuristic tier carries USD (floored, never a silent $0 — D1/F19); the row is an estimate.
  private func estimatedDebit(
    context: [ChatMessage],
    runId: Int64,
    sessionId: Int64
  ) -> ProviderUsage {
    let resolvedUsage = usageResolver.estimate(
      context: context,
      maxOutputTokens: budget.maxOutputTokens
    )
    let resolvedCost = costResolver.resolve(
      model: model,
      usage: resolvedUsage.usage,
      providerCost: nil
    )
    return ProviderUsage(
      runId: runId,
      sessionId: sessionId,
      model: model,
      usage: resolvedUsage,
      cost: resolvedCost,
      ts: Date()
    )
  }
}
