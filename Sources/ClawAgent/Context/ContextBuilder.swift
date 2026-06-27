import ClawCore
import Foundation

/// Greedy-by-priority §9 context assembly (grapheme domain). The system prompt is always the
/// first message and is never dropped; recent history is kept newest-first until the grapheme
/// cap is reached, then restored to chronological order. When older history was dropped, a
/// literal truncation marker is appended to the system prompt content.
public enum ContextBuilder {
  /// - Parameters:
  ///   - systemPrompt: the trusted built-in prompt (Inc 1) — never dropped.
  ///   - history: session messages, oldest-first.
  ///   - inputCapGraphemes: the §9 grapheme budget for the whole context.
  /// - Returns: `[system] + fitting history`, in chronological order.
  public static func assemble(
    systemPrompt: String,
    history: [StoredMessage],
    inputCapGraphemes: Int
  ) -> [ChatMessage] {
    var inputCappedMessages = [StoredMessage]()
    inputCappedMessages.reserveCapacity(history.count)

    var isBudgetExhausted = false
    var budget = inputCapGraphemes - systemPrompt.count

    // Walk newest → oldest. The newest message (index 0) is the current user turn, kept
    // unconditionally even if it alone exceeds the budget; older messages are dropped to fit.
    for (index, message) in history.reversed().enumerated() {
      budget -= message.content.count

      if budget < 0 && index > 0 {
        isBudgetExhausted = true
        break
      }

      inputCappedMessages.append(message)
    }

    let budgetExhaustedMarker = "\n\n[…earlier conversation truncated]"
    let systemMessage = ChatMessage(
      role: .system,
      content: isBudgetExhausted ? systemPrompt + budgetExhaustedMarker : systemPrompt
    )

    return [systemMessage] + inputCappedMessages.reversed().map(ChatMessage.init)
  }
}

extension ChatMessage {
  init(_ stored: StoredMessage) {
    self.init(role: stored.role, content: stored.content)
  }
}
