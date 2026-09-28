import ClawCore

/// Who a turn runs for and where its progress goes, fixed for the whole turn segment.
struct TurnScope: Sendable, Equatable {
  let runID: Int64
  let sessionID: Int64
  let chatID: Int64
  let threadID: Int64?
  let mode: ChatMode
  let origin: RunOrigin
  let requesterUserID: Int64?
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
