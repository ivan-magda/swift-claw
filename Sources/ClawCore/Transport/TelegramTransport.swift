/// The poller-facing intake half of the channel port: long-poll the channel for raw updates.
public protocol ChannelIntake: Sendable {
  /// `allowedUpdates` MUST be re-sent on every call — omitting it reuses the previous
  /// server-side setting.
  func getUpdates(
    offset: Int64?,
    timeout: Int,
    allowedUpdates: [String]
  ) async throws -> [RawUpdate]
}

/// The delivery half of the channel port: everything the gateway needs to put a message in front
/// of the owner. Outbox, replies, and cap notices depend on THIS, never on the Telegram composite.
public protocol MessageDelivery: Sendable {
  /// Returns the `message_id` Telegram assigned to the sent message — the outbox dispatcher records
  /// it against the delivered row so a redelivered row maps back to a known sent message.
  func sendMessage(chatId: Int64, text: String) async throws -> Int64
  /// Sends a rich-markdown message (`sendRichMessage` / `InputRichMessage{ markdown }`, Bot API 10.1).
  /// The markdown string is passed verbatim — no escaper, no converter — and rendered server-side.
  /// Returns the assigned `message_id` like `sendMessage`. On any rich-send error the dispatcher
  /// re-sends the chunk as plain `sendMessage`, so this never has to succeed for a reply to land.
  func sendRichMessage(chatId: Int64, markdown: String) async throws -> Int64
  /// As `sendMessage`, but attaches an inline keyboard when `replyMarkup` is a Telegram
  /// `reply_markup` JSON string (nil = no keyboard). The approval prompt's buttons ride this.
  func sendMessage(chatId: Int64, text: String, replyMarkup: String?) async throws -> Int64
  /// As `sendRichMessage`, but attaches the same optional inline keyboard.
  func sendRichMessage(chatId: Int64, markdown: String, replyMarkup: String?) async throws -> Int64
}

/// Answers and disarms inline-button callbacks. A separate port so the callback handler can hold a
/// `any CallbackResponding` without the full Telegram composite.
public protocol CallbackResponding: Sendable {
  /// Called on EVERY callback, valid or not, to stop the client's button spinner. `text` is the
  /// optional neutral toast; a nil/empty toast is the fail-closed default.
  func answerCallbackQuery(id: String, text: String?) async throws
  /// Disarms the prompt's buttons on resolve; `replyMarkup` nil removes the keyboard entirely.
  func editMessageReplyMarkup(chatId: Int64, messageId: Int64, replyMarkup: String?) async throws
}

/// The full Telegram surface: intake + delivery plus the Telegram-specific extras (identity,
/// streaming drafts, chat actions, the command menu) that only `clawd` and the `ClawTelegram`
/// wrappers consume.
public protocol TelegramTransport: ChannelIntake, MessageDelivery, CallbackResponding {
  func getMe() async throws -> BotIdentity
  func sendRichMessageDraft(chatId: Int64, draftId: Int64, markdown: String) async throws -> Bool
  /// Emits a Telegram chat action (e.g. `"typing"`). Fire-and-forget: the action auto-expires (~5s),
  /// so callers re-issue it on an interval and ignore failures — a missing indicator is never fatal.
  func sendChatAction(chatId: Int64, action: String) async throws
  /// Registers the bot's command list with Telegram so the picker appears when a user types `/`.
  func setMyCommands(_ commands: [BotMenuCommand]) async throws
}

extension TelegramTransport {
  public func sendRichMessageDraft(
    chatId: Int64,
    draftId: Int64,
    markdown: String
  ) async throws -> Bool {
    throw TelegramError.transport("sendRichMessageDraft not implemented")
  }

  public func setMyCommands(_ commands: [BotMenuCommand]) async throws {}

  public func answerCallbackQuery(id: String, text: String?) async throws {
    throw TelegramError.transport("answerCallbackQuery not implemented")
  }

  public func editMessageReplyMarkup(
    chatId: Int64,
    messageId: Int64,
    replyMarkup: String?
  ) async throws {
    throw TelegramError.transport("editMessageReplyMarkup not implemented")
  }
}

extension MessageDelivery {
  public func sendMessage(chatId: Int64, text: String, replyMarkup: String?) async throws -> Int64 {
    guard replyMarkup == nil else {
      throw TelegramError.transport("sendMessage(replyMarkup:) not implemented")
    }
    return try await sendMessage(chatId: chatId, text: text)
  }

  public func sendRichMessage(
    chatId: Int64,
    markdown: String,
    replyMarkup: String?
  ) async throws -> Int64 {
    guard replyMarkup == nil else {
      throw TelegramError.transport("sendRichMessage(replyMarkup:) not implemented")
    }
    return try await sendRichMessage(chatId: chatId, markdown: markdown)
  }
}

public protocol RichDraftStreaming: Sendable {
  func sendDraft(chatId: Int64, draftId: Int64, markdown: String) async
}

public struct NoopRichDraftStreaming: RichDraftStreaming {
  public init() {}

  public func sendDraft(chatId: Int64, draftId: Int64, markdown: String) async {}
}
