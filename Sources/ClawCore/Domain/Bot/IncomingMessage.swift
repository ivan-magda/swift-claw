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

  public init(
    messageId: Int64,
    fromUserId: Int64?,
    chatId: Int64,
    text: String?,
    caption: String?,
    mediaKind: String?,
    voice: VoiceAttachment? = nil,
    photo: PhotoAttachment? = nil
  ) {
    self.messageId = messageId
    self.fromUserId = fromUserId
    self.chatId = chatId
    self.text = text
    self.caption = caption
    self.mediaKind = mediaKind
    self.voice = voice
    self.photo = photo
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
  /// A photo and its caption are one message and travel together as `.photo`; written text outranks
  /// a *voice* attachment, because a transcript and a caption are two texts with no natural merge,
  /// so a captioned voice stays a text message. A caption on media with no usable attachment counts
  /// as text; other bare media maps to `.unsupported`.
  public static func normalize(from raw: RawUpdate) -> IncomingMessage? {
    guard
      let message = raw.message ?? raw.editedMessage,
      let fromUserId = message.fromUserId
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
      isEdited: raw.message == nil && raw.editedMessage != nil
    )
  }
}
