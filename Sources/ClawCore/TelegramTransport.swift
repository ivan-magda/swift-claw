public protocol TelegramTransport: Sendable {
  func getMe() async throws -> BotIdentity
  /// `allowedUpdates` MUST be re-sent on every call — omitting it reuses the previous server-side setting.
  func getUpdates(
    offset: Int64?,
    timeout: Int,
    allowedUpdates: [String]
  ) async throws -> [RawUpdate]
  /// Returns the `message_id` Telegram assigned to the sent message — the outbox dispatcher records
  /// it against the delivered row (§6.4) so a redelivered row maps back to a known sent message.
  func sendMessage(chatId: Int64, text: String) async throws -> Int64
  /// Sends a rich-markdown message (`sendRichMessage` / `InputRichMessage{ markdown }`, Bot API 10.1).
  /// The markdown string is passed verbatim — no escaper, no converter — and rendered server-side.
  /// Returns the assigned `message_id` like `sendMessage`. On any rich-send error the dispatcher
  /// re-sends the chunk as plain `sendMessage` (F8), so this never has to succeed for a reply to land.
  func sendRichMessage(chatId: Int64, markdown: String) async throws -> Int64
  /// Emits a Telegram chat action (e.g. `"typing"`). Fire-and-forget: the action auto-expires (~5s),
  /// so callers re-issue it on an interval and ignore failures — a missing indicator is never fatal.
  func sendChatAction(chatId: Int64, action: String) async throws
}
