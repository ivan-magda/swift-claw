public struct TurnToolStepID: Sendable, Hashable {
  public let providerCallID: String
  public let toolCallID: String

  public init(providerCallID: String, toolCallID: String) {
    self.providerCallID = providerCallID
    self.toolCallID = toolCallID
  }
}

public enum ToolProgressState: Sendable, Equatable {
  case pending
  case awaitingApproval
  case executing
  case succeeded
  case failed
  case denied
  case cancelled
}

public enum TurnProgressEvent: Sendable, Equatable {
  case modelStarted(providerCallID: String)
  case answerPreview(String)
  case explanation(LLMProgressEvent)
  /// Identity comes from registration. Nil uses a generic failed-step label, never model identity.
  case toolStarted(id: TurnToolStepID, tool: ToolDefinition?, preview: String?)
  case toolState(id: TurnToolStepID, state: ToolProgressState)
  case waitingForApproval(id: TurnToolStepID)
}

/// Updates presentation state without granting execution authority or waiting for delivery.
public struct TurnProgressReporter: Sendable {
  public let explanationsEnabled: Bool
  private let publishEvent: @Sendable (TurnProgressEvent) async -> Void

  public init(
    explanationsEnabled: Bool,
    publish: @escaping @Sendable (TurnProgressEvent) async -> Void
  ) {
    self.explanationsEnabled = explanationsEnabled
    publishEvent = publish
  }

  public func publish(_ event: TurnProgressEvent) async {
    await publishEvent(event)
  }
}

/// Reports one call. The agent binds its step ID; dispatch supplies registered identity and preview.
public struct ToolProgressReporter: Sendable {
  private let identifyTool: @Sendable (ToolDefinition?, String?) async -> Void
  private let publishState: @Sendable (ToolProgressState) async -> Void

  public init(
    identify: @escaping @Sendable (ToolDefinition?, String?) async -> Void,
    publish: @escaping @Sendable (ToolProgressState) async -> Void
  ) {
    identifyTool = identify
    publishState = publish
  }

  public func identify(tool: ToolDefinition?, preview: String?) async {
    await identifyTool(tool, preview)
  }

  public func publish(_ state: ToolProgressState) async {
    await publishState(state)
  }
}
