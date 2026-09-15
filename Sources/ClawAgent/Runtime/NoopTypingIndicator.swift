import ClawCore

package struct NoopTypingIndicator: TypingIndicator {
  package init() {}

  package func sendTyping(chatID: Int64, messageThreadID: Int64?) async {}
}
