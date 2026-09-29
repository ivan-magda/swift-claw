import ClawCore

/// What the next round sends and what the gateway persists: the wire, and every round-trip that
/// proposed tool calls. Observations re-enter the wire fenced under their tool's declared label.
struct TurnTranscript {
  private(set) var wire: [ChatMessage]
  /// Every round-trip that proposed tool calls, to persist.
  private(set) var exchanges: [ToolExchange] = []

  private let fenceLabels: ToolFenceLabels

  init(wire: [ChatMessage], toolDefinitions: [ToolDefinition]) {
    self.wire = wire
    fenceLabels = ToolFenceLabels(definitions: toolDefinitions)
  }

  /// Appends one round's assistant proposal and its fenced observations to the wire, and records
  /// the exchange for persistence.
  mutating func append(_ response: ChatResponse, observations: [ToolObservation]) {
    wire.append(
      ChatMessage(
        role: .assistant,
        content: response.content,
        toolCalls: response.toolCalls,
        providerState: response.providerState
      )
    )

    for observation in observations {
      wire.append(
        ChatMessage(
          role: .tool,
          content: LabeledContextFactory.make(
            label: fenceLabels.label(forToolNamed: observation.toolName),
            content: observation.content
          ).render(),
          toolCallID: observation.callID
        )
      )
    }

    exchanges.append(
      ToolExchange(
        assistantContent: response.content,
        toolCalls: response.toolCalls,
        observations: observations,
        providerState: response.providerState
      )
    )
  }
}
