import ClawCore
import Foundation

// MARK: - Provider roster builders

public func makeSingleRouteRoster(
  provider: any LLMProvider,
  wireModel: String,
  configuredReference: String? = nil,
  costPolicy: LLMCostPolicy = .metered,
  reservationPolicy: LLMInputReservationPolicy = .textOnly
) -> ProviderRoster {
  ProviderRoster(bindings: [
    LLMRouteBinding(
      provider: provider,
      wireModel: wireModel,
      configuredReference: configuredReference ?? wireModel,
      costPolicy: costPolicy,
      reservationPolicy: reservationPolicy
    )
  ])
}

// MARK: - Response/outcome builders

public func okResponse(
  content: String = "Hello there",
  finishReason: String = "stop",
  usage: ChatUsage? = ChatUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15),
  costFromProvider: Double? = 0.0021,
  providerState: ProviderExchangeState? = nil
) -> ChatResponse {
  ChatResponse(
    content: content,
    finishReason: finishReason,
    usage: usage,
    costFromProvider: costFromProvider,
    providerState: providerState
  )
}

public func okOutcome(
  content: String = "ok",
  ingestedUntrusted: Bool = true,
  readPrivateData: Bool = false
) -> @Sendable (ToolCall, ToolDispatchContext) -> ToolDispatchOutcome {
  { call, _ in
    ToolDispatchOutcome(
      observation: ToolObservation(
        callId: call.id,
        toolName: call.name,
        content: content,
        status: .ok,
        ingestedUntrusted: ingestedUntrusted,
        readPrivateData: readPrivateData
      ),
      argsRedacted: call.argumentsJSON
    )
  }
}

public func toolCallResponse(
  _ calls: [ToolCall],
  content: String = "",
  providerState: ProviderExchangeState? = nil
) -> ChatResponse {
  ChatResponse(
    content: content,
    finishReason: "tool_calls",
    usage: ChatUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15),
    costFromProvider: nil,
    toolCalls: calls,
    providerState: providerState
  )
}

public func fetchProposal(id: String = "c1", url: String = "https://example.com/a") -> ToolCall {
  ToolCall(id: id, name: "web_fetch", argumentsJSON: "{\"url\":\"\(url)\"}")
}

/// One `ProviderUsage` row for tests that build a `TurnOutcome` directly rather than deriving it
/// from a provider round-trip. `sessionId` is required (not defaulted) because the row is only
/// insertable against a real session — an FK-mismatched default would fail silently for callers
/// who forgot to pass their fixture's id.
public func usageFixture(
  sessionId: Int64,
  runId: Int64? = nil,
  model: String = "test-model",
  promptTokens: Int = 10,
  completionTokens: Int = 5,
  costUSD: Double = 0.001,
  costSource: CostSource = .heuristic
) -> ProviderUsage {
  ProviderUsage(
    providerCallID: UUIDProviderCallIDGenerator().next(),
    runId: runId,
    sessionId: sessionId,
    model: model,
    promptTokens: promptTokens,
    completionTokens: completionTokens,
    costUSD: costUSD,
    costSource: costSource,
    isEstimated: false,
    ts: Date()
  )
}
