public protocol TelegramTransport: Sendable {
  func getMe() async throws -> BotIdentity
  /// `allowedUpdates` MUST be re-sent on every call — omitting it reuses the previous server-side setting.
  func getUpdates(
    offset: Int64?,
    timeout: Int,
    allowedUpdates: [String]
  ) async throws -> [RawUpdate]
  func sendMessage(chatId: Int64, text: String) async throws
}
