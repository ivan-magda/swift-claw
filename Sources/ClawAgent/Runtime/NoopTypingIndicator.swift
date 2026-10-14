// periphery:ignore:all - documented empty collaborators, docs/ARCHITECTURE.md §3
import ClawCore

package struct NoopTypingIndicator: TypingIndicator {
  package init() {}

  package func sendTyping(chatID: Int64, messageThreadID: Int64?) async {}
}
