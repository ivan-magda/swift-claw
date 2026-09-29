import ClawCore

/// Who a turn runs for and where its progress goes, fixed for the whole turn segment.
public struct TurnScope: Sendable, Equatable {
  /// The durable run to charge and audit.
  public let runID: Int64
  /// The conversation that owns the run.
  public let sessionID: Int64
  /// The chat receiving progress updates.
  public let chatID: Int64
  /// The forum topic receiving progress, or nil for a chat without a topic ID.
  public let threadID: Int64?
  /// The conversation's frozen direct or group mode.
  public let mode: ChatMode
  /// Selects interactive or proactive budget and privilege restrictions.
  public let origin: RunOrigin
  /// The original sender whose identity follows group actions.
  public let requesterUserID: Int64?

  public init(
    runID: Int64,
    sessionID: Int64,
    chatID: Int64,
    threadID: Int64?,
    mode: ChatMode,
    origin: RunOrigin,
    requesterUserID: Int64?
  ) {
    self.runID = runID
    self.sessionID = sessionID
    self.chatID = chatID
    self.threadID = threadID
    self.mode = mode
    self.origin = origin
    self.requesterUserID = requesterUserID
  }
}

extension TurnScope {
  /// The sender a tool call acts for. Only an interactive turn has one: a direct chat falls back
  /// to its own chat id, while a group turn without a recorded sender has none, so a
  /// requester-bound tool fails closed.
  var toolRequesterUserID: Int64? {
    guard origin == .interactive else {
      return nil
    }

    if let requesterUserID {
      return requesterUserID
    }

    return mode == .direct ? chatID : nil
  }

  /// Where the turn's typing pulses and streaming drafts land.
  var progressTarget: TurnProgressTarget {
    TurnProgressTarget(chatID: chatID, threadID: threadID, draftID: runID)
  }

  /// The identity one tool call executes under.
  func executionContext(toolCallID: String) -> ToolExecutionContext {
    ToolExecutionContext(
      runID: runID,
      sessionID: sessionID,
      chatID: chatID,
      requesterUserID: toolRequesterUserID,
      origin: origin,
      mode: mode,
      toolCallID: toolCallID,
      approvalID: nil
    )
  }
}
