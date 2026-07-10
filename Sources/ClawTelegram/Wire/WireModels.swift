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

/// Bot API 7.0+ `link_preview_options` (outbound controls strip auto-fetching link elements).
/// Sent unconditionally disabled so Telegram's servers never fetch a URL embedded
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

/// Bot API `CallbackQuery` — an inline-button tap. `from` is never absent (a callback always has a
/// sender), unlike `TMessage.from`; `message` is present when the button rode a message we can
/// still edit; `data` carries the ≤64-byte `callback_data` we set on the button.
struct TCallbackQuery: Decodable {
  let id: String
  let from: TUser
  let message: TMessage?
  let data: String?
}

/// The inline-keyboard wire shape Telegram expects inside `reply_markup`:
/// `{"inline_keyboard":[[{"text":…,"callback_data":…}]]}`. This is the authoritative shape the
/// approval keyboard's JSON string must reproduce; the client sends the string parsed to a
/// `JSONValue`, so these Encodable types are the contract, not the send path.
struct TInlineKeyboardButton: Encodable {
  let text: String
  let callback_data: String
}
struct TInlineKeyboardMarkup: Encodable {
  let inline_keyboard: [[TInlineKeyboardButton]]
}

struct TUpdate: Decodable {
  let update_id: Int64
  let message: TMessage?
  let edited_message: TMessage?
  let callback_query: TCallbackQuery?

  // The button tap decodes here and maps into the wire-agnostic RawUpdate.callback; chat/message
  // ids come from the prompt message (callback_query.message), which Telegram always includes for
  // an inline-keyboard tap.
  func toRawUpdate() -> RawUpdate {
    RawUpdate(
      updateId: update_id,
      message: message?.toRawMessage(),
      editedMessage: edited_message?.toRawMessage(),
      callback: callback_query.map { query in
        RawCallback(
          callbackId: query.id,
          fromUserId: query.from.id,
          chatId: query.message?.chat.id,
          messageId: query.message?.message_id,
          data: query.data
        )
      }
    )
  }
}
// swiftlint:enable identifier_name discouraged_optional_boolean discouraged_optional_collection
