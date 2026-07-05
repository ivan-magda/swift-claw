// swift-format-ignore-file: AlwaysUseLowerCamelCase

// swiftlint:disable identifier_name discouraged_optional_boolean discouraged_optional_collection
// Wire structs mirror Telegram's API: snake_case keys, and optionals model absent JSON fields.
import ClawCore

struct TResponse<R: Decodable>: Decodable {
  let ok: Bool
  let result: R?
  let error_code: Int?
  let description: String?
  let parameters: TResponseParameters?
}
struct TResponseParameters: Decodable {
  let retry_after: Int?
}

struct TUser: Decodable {
  let id: Int64
  let is_bot: Bool?
  let username: String?
}
struct TChat: Decodable {
  let id: Int64
}

/// Media markers — presence is all that's needed to classify an unsupported kind.
struct TPresence: Decodable {}

struct TMessage: Decodable {
  let message_id: Int64
  let from: TUser?
  let chat: TChat
  let text: String?
  let caption: String?
  let photo: [TPresence]?
  let voice: TPresence?
  let document: TPresence?
  let sticker: TPresence?
  let video: TPresence?
  let audio: TPresence?

  var mediaKind: String? {
    if photo != nil { return "photos" }
    if voice != nil { return "voice messages" }
    if document != nil { return "documents" }
    if sticker != nil { return "stickers" }
    if video != nil { return "videos" }
    if audio != nil { return "audio" }
    return nil
  }

  func toRawMessage() -> RawMessage {
    RawMessage(
      messageId: message_id,
      fromUserId: from?.id,
      chatId: chat.id,
      text: text,
      caption: caption,
      mediaKind: mediaKind
    )
  }
}

/// The rich-content payload of `sendRichMessage` (Bot API 10.1). Telegram accepts exactly one of
/// `markdown`/`html`; we only ever send `markdown` (rendered server-side, no escaper/converter).
struct InputRichMessage: Encodable {
  let markdown: String
}

/// Bot API 7.0+ `link_preview_options` (ARCHITECTURE §12: outbound controls strip auto-fetching
/// link elements). Sent unconditionally disabled so Telegram's servers never fetch a URL embedded
/// in outbound text — including attacker-chosen URLs quoted back in a tool-approval prompt.
struct LinkPreviewOptions: Encodable {
  let isDisabled: Bool
}

struct SendRichMessageDraftRequest: Encodable {
  let chatId: Int64
  let draftId: Int64
  let richMessage: InputRichMessage
  let linkPreviewOptions: LinkPreviewOptions
}

struct TUpdate: Decodable {
  let update_id: Int64
  let message: TMessage?
  let edited_message: TMessage?

  func toRawUpdate() -> RawUpdate {
    RawUpdate(
      updateId: update_id,
      message: message?.toRawMessage(),
      editedMessage: edited_message?.toRawMessage()
    )
  }
}
// swiftlint:enable identifier_name discouraged_optional_boolean discouraged_optional_collection
