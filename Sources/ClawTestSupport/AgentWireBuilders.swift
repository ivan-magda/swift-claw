import ClawCore

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
