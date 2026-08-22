/// Where one outbound message lands: the chat, the forum topic inside it, and the message it
/// answers. Both optionals are absent for a DM, so a direct-mode send stays byte-identical to the
/// single-chat spelling that predates group mode.
public struct DeliveryTarget: Sendable, Equatable {
  public let chatId: Int64
  public let messageThreadId: Int64?
  public let replyToMessageId: Int64?

  public init(chatId: Int64, messageThreadId: Int64? = nil, replyToMessageId: Int64? = nil) {
    self.chatId = chatId
    self.messageThreadId = messageThreadId
    self.replyToMessageId = replyToMessageId
  }

  /// The whole-chat target: no topic, no reply. Every DM send uses it, as does any notice with no
  /// calling message to answer.
  public static func chat(_ chatId: Int64) -> DeliveryTarget {
    DeliveryTarget(chatId: chatId)
  }

  /// Where an answer to `message` belongs: in a room, the topic it was asked in, threaded under the
  /// message that asked, so a burst of concurrent questions stays legible.
  public static func reply(to message: IncomingMessage, mode: ChatMode) -> DeliveryTarget {
    switch mode {
    case .direct:
      .chat(message.chatId)
    case .group:
      DeliveryTarget(
        chatId: message.chatId,
        messageThreadId: message.messageThreadId,
        replyToMessageId: message.messageId
      )
    }
  }
}
