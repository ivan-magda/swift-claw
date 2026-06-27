/// Emits a Telegram "typing…" chat action for a chat. The action auto-expires (~5s) and has no
/// clear API (F5), so the runtime re-issues it on an interval during a turn. The concrete impl
/// is Telegram-backed and injected by the gateway; tests use a recording mock.
public protocol TypingIndicator: Sendable {
  func sendTyping(chatId: Int64) async
}
