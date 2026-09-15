/// Where one outbound message lands: the chat, the forum topic inside it, and the message it
/// answers. Both optionals are absent for a DM, so a direct-mode send stays byte-identical to the
/// single-chat spelling that predates group mode.
public struct DeliveryTarget: Sendable, Equatable {
  public let chatID: Int64
  public let messageThreadID: Int64?
  public let replyToMessageID: Int64?

  public init(chatID: Int64, messageThreadID: Int64? = nil, replyToMessageID: Int64? = nil) {
    self.chatID = chatID
    self.messageThreadID = messageThreadID
    self.replyToMessageID = replyToMessageID
  }

  /// The whole-chat target: no topic, no reply. Every DM send uses it, as does any notice with no
  /// calling message to answer.
  public static func chat(_ chatID: Int64) -> DeliveryTarget { DeliveryTarget(chatID: chatID) }

  /// Where an answer to `message` belongs: in a room, the topic it was asked in, threaded under the
  /// message that asked, so a burst of concurrent questions stays legible.
  public static func reply(to message: IncomingMessage, mode: ChatMode) -> DeliveryTarget {
    switch mode {
    case .direct: .chat(message.chatID)
    case .group:
      DeliveryTarget(
        chatID: message.chatID,
        messageThreadID: message.messageThreadID,
        replyToMessageID: message.messageID
      )
    }
  }
}
