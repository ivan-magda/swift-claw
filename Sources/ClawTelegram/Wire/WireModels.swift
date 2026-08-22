// swift-format-ignore-file: AlwaysUseLowerCamelCase

// swiftlint:disable identifier_name discouraged_optional_boolean discouraged_optional_collection
// Wire structs mirror Telegram's API: snake_case keys, and optionals model absent JSON fields.
import ClawCore
import Foundation

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
  let first_name: String?
  let last_name: String?

  /// What a group reader would see above the message: the given name(s), else the @username.
  var displayName: String? {
    let parts = [first_name, last_name].compactMap { part in
      part?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let name = parts.filter { !$0.isEmpty }.joined(separator: " ")
    return name.isEmpty ? username : name
  }
}
struct TChat: Decodable {
  let id: Int64
  let type: String?
  let is_forum: Bool?
  let title: String?

  /// Bot API always sends `type`; an absent one is malformed. It maps to `.private` so a
  /// malformed payload keeps the pre-group-mode DM behavior — group mode additionally requires an
  /// allowlisted chat id, so this default can never promote a chat into it.
  var kind: ChatKind {
    type.map(ChatKind.init(apiValue:)) ?? .private
  }
}

/// The `reply_to_message` target, decoded as its own shape rather than a nested `TMessage`
/// (a struct cannot recursively contain itself) — only the ids the addressing check needs.
struct TReplyTarget: Decodable {
  let message_id: Int64?
  let from: TUser?
}

/// Media markers — presence is all that's needed to classify an unsupported kind.
struct TPresence: Decodable {}

/// Bot API `Voice`: the download handle plus the metadata the pipeline guards on before fetching.
/// Every field is optional on purpose — a voice payload that is missing `file_id` (malformed or a
/// future API shape) must degrade to the presence-only "can't read voice messages" path, never
/// fail the whole `getUpdates` batch and stall intake.
struct TVoice: Decodable {
  let file_id: String?
  let duration: Int?
  let mime_type: String?
  let file_size: Int64?

  var attachment: VoiceAttachment? {
    guard let file_id else {
      return nil
    }
    return VoiceAttachment(
      fileId: file_id,
      durationSeconds: duration ?? 0,
      mimeType: mime_type,
      fileSizeBytes: file_size
    )
  }
}

/// Bot API `PhotoSize`. Every field is optional on purpose — a rung missing `file_id` (malformed or
/// a future API shape) must drop out of the ladder, never fail the whole `getUpdates` batch.
struct TPhotoSize: Decodable {
  let file_id: String?
  let file_unique_id: String?
  let width: Int?
  let height: Int?
  let file_size: Int64?

  var size: PhotoSize? {
    guard let file_id, let width, let height else {
      return nil
    }
    return PhotoSize(
      fileId: file_id,
      fileUniqueId: file_unique_id,
      width: width,
      height: height,
      fileSizeBytes: file_size
    )
  }
}

/// Bot API `File` (the `getFile` result); `file_path` feeds the file-download URL and can be
/// absent while Telegram is still preparing the file.
struct TFile: Decodable {
  let file_id: String
  let file_path: String?
}

struct TMessage: Decodable {
  let message_id: Int64
  let from: TUser?
  let chat: TChat
  let sender_chat: TChat?
  let message_thread_id: Int64?
  let reply_to_message: TReplyTarget?
  let migrate_to_chat_id: Int64?
  let text: String?
  let caption: String?
  let photo: [TPhotoSize]?
  let voice: TVoice?
  let document: TPresence?
  let sticker: TPresence?
  let video: TPresence?
  let audio: TPresence?

  var mediaKind: String? {
    if photo != nil { return PhotoAttachment.mediaKindDescription }
    if voice != nil { return VoiceAttachment.mediaKindDescription }
    if document != nil { return "documents" }
    if sticker != nil { return "stickers" }
    if video != nil { return "videos" }
    if audio != nil { return "audio" }
    return nil
  }

  var photoAttachment: PhotoAttachment? {
    guard let photo else {
      return nil
    }
    let sizes = photo.compactMap(\.size)
    return sizes.isEmpty ? nil : PhotoAttachment(sizes: sizes)
  }

  func toRawMessage() -> RawMessage {
    RawMessage(
      messageId: message_id,
      fromUserId: from?.id,
      chatId: chat.id,
      text: text,
      caption: caption,
      mediaKind: mediaKind,
      voice: voice?.attachment,
      photo: photoAttachment,
      chatKind: chat.kind,
      chatTitle: chat.title,
      messageThreadId: message_thread_id,
      replyToMessageId: reply_to_message?.message_id,
      replyToUserId: reply_to_message?.from?.id,
      senderDisplayName: from?.displayName,
      hasSenderChat: sender_chat != nil,
      migratedToChatId: migrate_to_chat_id
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
