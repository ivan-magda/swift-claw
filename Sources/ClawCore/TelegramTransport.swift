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
}
