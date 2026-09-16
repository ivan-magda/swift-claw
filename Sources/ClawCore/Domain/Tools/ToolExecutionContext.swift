public struct ToolExecutionContext: Sendable, Equatable {
  public let runID: Int64
  public let sessionID: Int64
  public let chatID: Int64
  public let requesterUserID: Int64?
  public let origin: RunOrigin
  public let mode: ChatMode
  public let toolCallID: String
  public let approvalID: Int64?

  public init(
    runID: Int64,
    sessionID: Int64,
    chatID: Int64,
    requesterUserID: Int64?,
    origin: RunOrigin,
    mode: ChatMode,
    toolCallID: String,
    approvalID: Int64?
  ) {
    self.runID = runID
    self.sessionID = sessionID
    self.chatID = chatID
    self.requesterUserID = requesterUserID
    self.origin = origin
    self.mode = mode
    self.toolCallID = toolCallID
    self.approvalID = approvalID
  }
}
