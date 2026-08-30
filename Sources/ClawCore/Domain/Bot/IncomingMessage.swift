/// Wire-agnostic update: `ClawCore` never imports the Telegram JSON model (it lives in `ClawTelegram`).
public struct RawUpdate: Sendable, Equatable {
  public let updateId: Int64
  public let message: RawMessage?
  public let editedMessage: RawMessage?
  public let callback: RawCallback?
  /// The bot's own membership changing in a chat. Carries no message and is only ever logged.
  public let myChatMember: RawChatMemberUpdate?

  public init(
    updateId: Int64,
    message: RawMessage?,
    editedMessage: RawMessage?,
    callback: RawCallback? = nil,
    myChatMember: RawChatMemberUpdate? = nil
  ) {
    self.updateId = updateId
    self.message = message
    self.editedMessage = editedMessage
    self.callback = callback
    self.myChatMember = myChatMember
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

/// The wire-agnostic voice attachment: the download handle plus the metadata the pipeline
/// guards on before fetching a single byte (duration and declared size caps).
public struct VoiceAttachment: Sendable, Equatable {
  /// The pluralized noun the wire layer and the canned "can't read X yet" reply share.
  public static let mediaKindDescription = "voice messages"

  public let fileId: String
  public let durationSeconds: Int
  public let mimeType: String?
  public let fileSizeBytes: Int64?

  public init(fileId: String, durationSeconds: Int, mimeType: String?, fileSizeBytes: Int64?) {
    self.fileId = fileId
    self.durationSeconds = durationSeconds
    self.mimeType = mimeType
    self.fileSizeBytes = fileSizeBytes
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
  public let voice: VoiceAttachment?
  public let photo: PhotoAttachment?
  public let chatKind: ChatKind
  /// The room's name, for the operator-facing log that is the only way to learn an unlisted
  /// group's chat id. Absent in a DM.
  public let chatTitle: String?
  /// The forum topic. Absent in the General topic and in every non-forum chat, and never coerced
  /// to a topic id — the General topic and topic 1 are two different conversations.
  public let messageThreadId: Int64?
  public let replyToMessageId: Int64?
  public let replyToUserId: Int64?
  public let senderDisplayName: String?
  /// The message was sent on behalf of a chat (anonymous admin, channel post): the sender id
  /// identifies no human.
  public let hasSenderChat: Bool
  public let migratedToChatId: Int64?

  public init(
    messageId: Int64,
    fromUserId: Int64?,
    chatId: Int64,
    text: String?,
    caption: String?,
    mediaKind: String?,
    voice: VoiceAttachment? = nil,
    photo: PhotoAttachment? = nil,
    chatKind: ChatKind = .private,
    chatTitle: String? = nil,
    messageThreadId: Int64? = nil,
    replyToMessageId: Int64? = nil,
    replyToUserId: Int64? = nil,
    senderDisplayName: String? = nil,
    hasSenderChat: Bool = false,
    migratedToChatId: Int64? = nil
  ) {
    self.messageId = messageId
    self.fromUserId = fromUserId
    self.chatId = chatId
    self.text = text
    self.caption = caption
    self.mediaKind = mediaKind
    self.voice = voice
    self.photo = photo
    self.chatKind = chatKind
    self.chatTitle = chatTitle
    self.messageThreadId = messageThreadId
    self.replyToMessageId = replyToMessageId
    self.replyToUserId = replyToUserId
    self.senderDisplayName = senderDisplayName
    self.hasSenderChat = hasSenderChat
    self.migratedToChatId = migratedToChatId
  }
}

public struct IncomingMessage: Sendable, Equatable {
  public enum Content: Sendable, Equatable {
    case text(String)
    case voice(VoiceAttachment)
    case photo(PhotoAttachment, caption: String?)
    case unsupported(kind: String)
  }

  public let updateId: Int64
  public let messageId: Int64
  public let userId: Int64
  public let chatId: Int64
  public let content: Content
  public let isEdited: Bool
  public let chatKind: ChatKind
  /// The room's name, absent in a DM.
  public let chatTitle: String?
  /// The forum topic, absent in the General topic and in every non-forum chat.
  public let messageThreadId: Int64?
  public let replyToMessageId: Int64?
  public let replyToUserId: Int64?
  public let senderDisplayName: String?
  public let migratedToChatId: Int64?

  public init(
    updateId: Int64,
    messageId: Int64,
    userId: Int64,
    chatId: Int64,
    content: Content,
    isEdited: Bool,
    chatKind: ChatKind = .private,
    chatTitle: String? = nil,
    messageThreadId: Int64? = nil,
    replyToMessageId: Int64? = nil,
    replyToUserId: Int64? = nil,
    senderDisplayName: String? = nil,
    migratedToChatId: Int64? = nil
  ) {
    self.updateId = updateId
    self.messageId = messageId
    self.userId = userId
    self.chatId = chatId
    self.content = content
    self.isEdited = isEdited
    self.chatKind = chatKind
    self.chatTitle = chatTitle
    self.messageThreadId = messageThreadId
    self.replyToMessageId = replyToMessageId
    self.replyToUserId = replyToUserId
    self.senderDisplayName = senderDisplayName
    self.migratedToChatId = migratedToChatId
  }

  /// Pure normalization (no I/O). Returns nil when there's nothing actionable:
  /// no message/edited_message, no numeric sender, empty content, or a sender that is a chat
  /// rather than a person (anonymous admin, channel post) — the id such a message carries belongs
  /// to Telegram's relay bot, so allowing on it would allow anyone posting behind the chat.
  /// A photo and its caption are one message and travel together as `.photo`; written text outranks
  /// a *voice* attachment, because a transcript and a caption are two texts with no natural merge,
  /// so a captioned voice stays a text message. A caption on media with no usable attachment counts
  /// as text; other bare media maps to `.unsupported`.
  public static func normalize(from raw: RawUpdate) -> IncomingMessage? {
    guard
      let message = raw.message ?? raw.editedMessage,
      let fromUserId = message.fromUserId,
      !message.hasSenderChat
    else {
      return nil
    }

    let content: IncomingMessage.Content
    if let photo = message.photo {
      content = .photo(photo, caption: message.text ?? message.caption)
    } else if let text = message.text {
      content = .text(text)
    } else if let caption = message.caption {
      content = .text(caption)
    } else if let voice = message.voice {
      content = .voice(voice)
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
      isEdited: raw.message == nil && raw.editedMessage != nil,
      chatKind: message.chatKind,
      chatTitle: message.chatTitle,
      messageThreadId: message.messageThreadId,
      replyToMessageId: message.replyToMessageId,
      replyToUserId: message.replyToUserId,
      senderDisplayName: message.senderDisplayName,
      migratedToChatId: message.migratedToChatId
    )
  }
}
