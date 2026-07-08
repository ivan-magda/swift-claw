/// The poller-facing intake half of the channel port: long-poll the channel for raw updates.
/// Split from the delivery half (Risk 10) so a future second channel starts at a protocol, not
/// inside a Telegram-named contract.
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
  /// it against the delivered row (§6.4) so a redelivered row maps back to a known sent message.
  func sendMessage(chatId: Int64, text: String) async throws -> Int64
  /// Sends a rich-markdown message (`sendRichMessage` / `InputRichMessage{ markdown }`, Bot API 10.1).
  /// The markdown string is passed verbatim — no escaper, no converter — and rendered server-side.
  /// Returns the assigned `message_id` like `sendMessage`. On any rich-send error the dispatcher
  /// re-sends the chunk as plain `sendMessage` (F8), so this never has to succeed for a reply to land.
  func sendRichMessage(chatId: Int64, markdown: String) async throws -> Int64
}

/// The full Telegram surface: intake + delivery plus the Telegram-specific extras (identity,
/// streaming drafts, chat actions, the command menu) that only `clawd` and the `ClawTelegram`
/// wrappers consume.
public protocol TelegramTransport: ChannelIntake, MessageDelivery {
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
}

public protocol RichDraftStreaming: Sendable {
  func sendDraft(chatId: Int64, draftId: Int64, markdown: String) async
}

public struct NoopRichDraftStreaming: RichDraftStreaming {
  public init() {}

  public func sendDraft(chatId: Int64, draftId: Int64, markdown: String) async {}
}
