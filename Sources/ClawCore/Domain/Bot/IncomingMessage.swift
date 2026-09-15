/// Wire-agnostic update: `ClawCore` never imports the Telegram JSON model (it lives in `ClawTelegram`).
public struct RawUpdate: Sendable, Equatable {
  public let updateID: Int64
  public let message: RawMessage?
  public let editedMessage: RawMessage?
  public let callback: RawCallback?
  /// The bot's own membership changing in a chat. Carries no message and is only ever logged.
  public let myChatMember: RawChatMemberUpdate?

  public init(
    updateID: Int64,
    message: RawMessage?,
    editedMessage: RawMessage?,
    callback: RawCallback? = nil,
    myChatMember: RawChatMemberUpdate? = nil
  ) {
    self.updateID = updateID
    self.message = message
    self.editedMessage = editedMessage
    self.callback = callback
    self.myChatMember = myChatMember
  }
}

/// A tapped inline button, wire-agnostic like `RawUpdate` (ClawCore never imports the Telegram JSON
/// model). `chatID`/`messageID` come from the prompt message (`callback.message`) and drive the
/// keyboard-disarm edit; `data` is the raw `callback_data` parsed by `ApprovalKeyboard`.
public struct RawCallback: Sendable, Equatable {
  public let callbackID: String
  public let fromUserID: Int64
  public let chatID: Int64?
  public let messageID: Int64?
  public let data: String?

  public init(
    callbackID: String,
    fromUserID: Int64,
    chatID: Int64?,
    messageID: Int64?,
    data: String?
  ) {
    self.callbackID = callbackID
    self.fromUserID = fromUserID
    self.chatID = chatID
    self.messageID = messageID
    self.data = data
  }
}

/// The wire-agnostic voice attachment: the download handle plus the metadata the pipeline
/// guards on before fetching a single byte (duration and declared size caps).
public struct VoiceAttachment: Sendable, Equatable {
  /// The pluralized noun the wire layer and the canned "can't read X yet" reply share.
  public static let mediaKindDescription = "voice messages"

  public let fileID: String
  public let durationSeconds: Int
  public let mimeType: String?
  public let fileSizeBytes: Int64?

  public init(fileID: String, durationSeconds: Int, mimeType: String?, fileSizeBytes: Int64?) {
    self.fileID = fileID
    self.durationSeconds = durationSeconds
    self.mimeType = mimeType
    self.fileSizeBytes = fileSizeBytes
  }
}

public struct RawMessage: Sendable, Equatable {
  public let messageID: Int64
  public let fromUserID: Int64?
  public let chatID: Int64
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
  public let messageThreadID: Int64?
  public let replyToMessageID: Int64?
  public let replyToUserID: Int64?
  public let senderDisplayName: String?
  /// The message was sent on behalf of a chat (anonymous admin, channel post): the sender id
  /// identifies no human.
  public let hasSenderChat: Bool
  /// Telegram marked this message as forwarded; its sender did not author the content here.
  public let isForwarded: Bool
  public let migratedToChatID: Int64?

  public init(
    messageID: Int64,
    fromUserID: Int64?,
    chatID: Int64,
    text: String?,
    caption: String?,
    mediaKind: String?,
    voice: VoiceAttachment? = nil,
    photo: PhotoAttachment? = nil,
    chatKind: ChatKind = .private,
    chatTitle: String? = nil,
    messageThreadID: Int64? = nil,
    replyToMessageID: Int64? = nil,
    replyToUserID: Int64? = nil,
    senderDisplayName: String? = nil,
    hasSenderChat: Bool = false,
    isForwarded: Bool = false,
    migratedToChatID: Int64? = nil
  ) {
    self.messageID = messageID
    self.fromUserID = fromUserID
    self.chatID = chatID
    self.text = text
    self.caption = caption
    self.mediaKind = mediaKind
    self.voice = voice
    self.photo = photo
    self.chatKind = chatKind
    self.chatTitle = chatTitle
    self.messageThreadID = messageThreadID
    self.replyToMessageID = replyToMessageID
    self.replyToUserID = replyToUserID
    self.senderDisplayName = senderDisplayName
    self.hasSenderChat = hasSenderChat
    self.isForwarded = isForwarded
    self.migratedToChatID = migratedToChatID
  }
}

public struct IncomingMessage: Sendable, Equatable {
  public enum Content: Sendable, Equatable {
    case text(String)
    case voice(VoiceAttachment)
    case photo(PhotoAttachment, caption: String?)
    case unsupported(kind: String)
  }

  public let updateID: Int64
  public let messageID: Int64
  public let userID: Int64
  public let chatID: Int64
  public let content: Content
  public let isEdited: Bool
  public let chatKind: ChatKind
  /// The room's name, absent in a DM.
  public let chatTitle: String?
  /// The forum topic, absent in the General topic and in every non-forum chat.
  public let messageThreadID: Int64?
  public let replyToMessageID: Int64?
  public let replyToUserID: Int64?
  public let senderDisplayName: String?
  public let migratedToChatID: Int64?

  public init(
    updateID: Int64,
    messageID: Int64,
    userID: Int64,
    chatID: Int64,
    content: Content,
    isEdited: Bool,
    chatKind: ChatKind = .private,
    chatTitle: String? = nil,
    messageThreadID: Int64? = nil,
    replyToMessageID: Int64? = nil,
    replyToUserID: Int64? = nil,
    senderDisplayName: String? = nil,
    migratedToChatID: Int64? = nil
  ) {
    self.updateID = updateID
    self.messageID = messageID
    self.userID = userID
    self.chatID = chatID
    self.content = content
    self.isEdited = isEdited
    self.chatKind = chatKind
    self.chatTitle = chatTitle
    self.messageThreadID = messageThreadID
    self.replyToMessageID = replyToMessageID
    self.replyToUserID = replyToUserID
    self.senderDisplayName = senderDisplayName
    self.migratedToChatID = migratedToChatID
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
      let fromUserID = message.fromUserID,
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
      updateID: raw.updateID,
      messageID: message.messageID,
      userID: fromUserID,
      chatID: message.chatID,
      content: content,
      isEdited: raw.message == nil && raw.editedMessage != nil,
      chatKind: message.chatKind,
      chatTitle: message.chatTitle,
      messageThreadID: message.messageThreadID,
      replyToMessageID: message.replyToMessageID,
      replyToUserID: message.replyToUserID,
      senderDisplayName: message.senderDisplayName,
      migratedToChatID: message.migratedToChatID
    )
  }
}
