import ClawCore
import Logging

/// Outcome of routing one update — tells the poller whether it may advance the offset.
public enum HandleOutcome: Sendable, Equatable {
  case processed  // delivered a reply (or answered an unauthorized sender)
  case skipped  // duplicate or nothing actionable — safe to advance past
  case transientFailure  // claim/send failed transiently — do NOT advance; re-poll
}

public struct MessageRouter: Sendable {
  private let updateStore: any ProcessedUpdateStore
  private let accessControl: AccessControl
  private let transport: any TelegramTransport
  private let logger: Logger

  public init(
    updateStore: any ProcessedUpdateStore,
    accessControl: AccessControl,
    transport: any TelegramTransport,
    logger: Logger
  ) {
    self.updateStore = updateStore
    self.accessControl = accessControl
    self.transport = transport
    self.logger = logger
  }

  static let welcomeText = "Hi — I'm online. Send me a message and I'll echo it back."

  /// Returns an outcome instead of throwing so the poller advances the offset only when an
  /// update is fully handled and re-polls otherwise. A claim error is transient — nothing was
  /// committed, so re-delivery is safe. A send failure after a committed claim is the known
  /// at-least-once gap: dedup prevents a double echo, but the re-poll cannot resurrect the lost
  /// one (a transactional outbox closes this later).
  @discardableResult
  public func handle(rawUpdate: RawUpdate) async -> HandleOutcome {
    let claimed: Bool
    do {
      claimed = try updateStore.claimUpdate(updateId: rawUpdate.updateId)
    } catch {
      logger.error("claim failed for update \(rawUpdate.updateId): \(error)")
      return .transientFailure
    }

    guard claimed else {
      logger.debug("duplicate update \(rawUpdate.updateId), skipping")
      return .skipped
    }

    guard let normalizedMessage = IncomingMessage.normalize(from: rawUpdate) else {
      logger.debug("update \(rawUpdate.updateId) has nothing actionable, skipping")
      return .skipped
    }

    do {
      if accessControl.isAllowed(userId: normalizedMessage.userId) {
        try await reply(to: normalizedMessage)
      } else {
        try await replyUnauthorized(to: normalizedMessage)
      }
    } catch {
      logger.error("send failed for update \(rawUpdate.updateId): \(error)")
      return .transientFailure
    }

    return .processed
  }

  private func reply(to message: IncomingMessage) async throws {
    switch message.content {
    case .text(let text):
      if Self.isStart(text) {
        try await transport.sendMessage(chatId: message.chatId, text: Self.welcomeText)
      } else {
        let prefix = message.isEdited ? "You edited: " : "You said: "
        try await transport.sendMessage(chatId: message.chatId, text: prefix + text)
      }
    case .unsupported(let kind):
      try await transport.sendMessage(chatId: message.chatId, text: "I can't read \(kind) yet.")
    }
  }

  private func replyUnauthorized(to message: IncomingMessage) async throws {
    if case .text(let text) = message.content, Self.isStart(text) {
      // Onboarding: echo THEIR own id so they can self-allowlist.
      // Never reveal the allowlist; never grant access.
      try await transport.sendMessage(
        chatId: message.chatId,
        text: """
          This is a private bot. Your Telegram user ID is \(message.userId). Ask the owner to add it to the allowlist.
          """
      )
    } else {
      try await transport.sendMessage(
        chatId: message.chatId,
        text: "Sorry — this is a private bot."
      )
    }
  }

  private static func isStart(_ text: String) -> Bool {
    text == "/start" || text.hasPrefix("/start ") || text.hasPrefix("/start@")
  }
}
