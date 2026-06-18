import ClawCore
import Foundation

/// Records outbound sends; scripts getUpdates batches and optional errors for poller tests.
actor RecordingTransport: TelegramTransport {
  private(set) var sent: [(chatId: Int64, text: String)] = []
  private(set) var sendAttempts = 0
  private var batches: [[RawUpdate]]
  private let onExhausted: TelegramError?
  private let sendError: TelegramError?

  var sentCount: Int { sent.count }
  var attempts: Int { sendAttempts }

  init(
    batches: [[RawUpdate]] = [],
    throwAfterExhaustion: TelegramError? = nil,
    sendError: TelegramError? = nil
  ) {
    self.batches = batches
    self.onExhausted = throwAfterExhaustion
    self.sendError = sendError
  }

  func getMe() async throws -> BotIdentity { BotIdentity(id: 1, username: "claw_bot") }

  func getUpdates(
    offset: Int64?,
    timeout: Int,
    allowedUpdates: [String]
  ) async throws -> [RawUpdate] {
    if batches.isEmpty {
      if let onExhausted {
        throw onExhausted
      }
      try? await Task.sleep(for: .milliseconds(5))  // emulate an idle long-poll
      return []
    }
    return batches.removeFirst()
  }

  func sendMessage(chatId: Int64, text: String) async throws {
    sendAttempts += 1
    if let sendError {
      throw sendError  // simulate a transient send failure
    }
    sent.append((chatId, text))
  }
}

func textUpdate(id: Int64, from: Int64, chat: Int64? = nil, text: String) -> RawUpdate {
  RawUpdate(
    updateId: id,
    message: RawMessage(
      messageId: id,
      fromUserId: from,
      chatId: chat ?? from,
      text: text,
      caption: nil,
      mediaKind: nil
    ),
    editedMessage: nil
  )
}
