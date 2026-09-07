public struct ToolExecutionContext: Sendable, Equatable {
  public let runId: Int64
  public let sessionId: Int64
  public let chatId: Int64
  public let requesterUserId: Int64?
  public let origin: RunOrigin
  public let mode: ChatMode
  public let toolCallId: String
  public let approvalId: Int64?

  public init(
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    requesterUserId: Int64?,
    origin: RunOrigin,
    mode: ChatMode,
    toolCallId: String,
    approvalId: Int64?
  ) {
    self.runId = runId
    self.sessionId = sessionId
    self.chatId = chatId
    self.requesterUserId = requesterUserId
    self.origin = origin
    self.mode = mode
    self.toolCallId = toolCallId
    self.approvalId = approvalId
  }
}
