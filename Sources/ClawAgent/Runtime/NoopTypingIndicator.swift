import ClawCore

package struct NoopTypingIndicator: TypingIndicator {
  package init() {}

  package func sendTyping(chatId: Int64, messageThreadId: Int64?) async {}
}
