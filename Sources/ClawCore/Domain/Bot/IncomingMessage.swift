/// Wire-agnostic update: `ClawCore` never imports the Telegram JSON model (it lives in `ClawTelegram`).
public struct RawUpdate: Sendable, Equatable {
  public let updateId: Int64
  public let message: RawMessage?
  public let editedMessage: RawMessage?
  public let callback: RawCallback?

  public init(
    updateId: Int64,
    message: RawMessage?,
    editedMessage: RawMessage?,
    callback: RawCallback? = nil
  ) {
    self.updateId = updateId
    self.message = message
    self.editedMessage = editedMessage
    self.callback = callback
  }
}

/// A tapped inline button, wire-agnostic like `RawUpdate` (ClawCore never imports the Telegram JSON
/// model). `chatId`/`messageId` come from the prompt message (`callback.message`) and drive the
/// keyboard-disarm edit; `data` is the raw `callback_data` parsed by `ApprovalKeyboard`.
public struct RawCallback: Sendable, Equatable {
  public let callbackId: String
  public let fromUserId: Int64
  public let chatId: Int64?
  public let messageId: Int64?
  public let data: String?

  public init(
    callbackId: String,
    fromUserId: Int64,
    chatId: Int64?,
    messageId: Int64?,
    data: String?
  ) {
    self.callbackId = callbackId
    self.fromUserId = fromUserId
    self.chatId = chatId
    self.messageId = messageId
    self.data = data
  }
}

public struct RawMessage: Sendable, Equatable {
  public let messageId: Int64
  public let fromUserId: Int64?
  public let chatId: Int64
  public let text: String?
  public let caption: String?
  /// Pluralized noun for unsupported media ("photos", "voice messages"), else nil.
  public let mediaKind: String?

  public init(
    messageId: Int64,
    fromUserId: Int64?,
    chatId: Int64,
    text: String?,
    caption: String?,
    mediaKind: String?
  ) {
    self.messageId = messageId
    self.fromUserId = fromUserId
    self.chatId = chatId
    self.text = text
    self.caption = caption
    self.mediaKind = mediaKind
  }
}

public struct IncomingMessage: Sendable, Equatable {
  public enum Content: Sendable, Equatable {
    case text(String)
    case unsupported(kind: String)
  }

  public let updateId: Int64
  public let messageId: Int64
  public let userId: Int64
  public let chatId: Int64
  public let content: Content
  public let isEdited: Bool

  public init(
    updateId: Int64,
    messageId: Int64,
    userId: Int64,
    chatId: Int64,
    content: Content,
    isEdited: Bool
  ) {
    self.updateId = updateId
    self.messageId = messageId
    self.userId = userId
    self.chatId = chatId
    self.content = content
    self.isEdited = isEdited
  }

  /// Pure normalization (no I/O). Returns nil when there's nothing actionable:
  /// no message/edited_message, no numeric sender, or empty content.
  /// A media caption counts as text; bare media maps to `.unsupported`.
  public static func normalize(from raw: RawUpdate) -> IncomingMessage? {
    guard
      let message = raw.message ?? raw.editedMessage,
      let fromUserId = message.fromUserId
    else {
      return nil
    }

    let content: IncomingMessage.Content
    if let text = message.text {
      content = .text(text)
    } else if let caption = message.caption {
      content = .text(caption)
    } else if let mediaKind = message.mediaKind {
      content = .unsupported(kind: mediaKind)
    } else {
      return nil
    }

    return IncomingMessage(
      updateId: raw.updateId,
      messageId: message.messageId,
      userId: fromUserId,
      chatId: message.chatId,
      content: content,
      isEdited: raw.message == nil && raw.editedMessage != nil
    )
  }
}
