import ClawCore
import Foundation
import Logging

/// Outcome of routing one update — tells the poller whether it may advance the offset.
public enum HandleOutcome: Sendable, Equatable {
  case processed  // handled durably (turn dispatched, or a canned reply sent)
  case skipped  // duplicate or nothing actionable — safe to advance past
  case transientFailure  // claim/send failed transiently — do NOT advance; re-poll
  case storageFull  // disk full while persisting — notice sent; back off, do NOT advance
}

/// Routes one inbound update. Allowlisted plain text becomes a real LLM turn (persisted via the
/// fused `claimAndPersistInbound`, then dispatched to the `TurnRunner`); everything else —
/// `/start`, unauthorized senders, unsupported media — gets a direct canned reply deduped via
/// `claimUpdate`. The two dedup paths share the `processed_updates` key space, and each update
/// takes exactly one path, so an update is claimed once.
public struct MessageRouter: Sendable {
  private let processed: any ProcessedUpdateStore
  private let sessionMessages: any SessionMessageStore
  private let accessControl: AccessControl
  private let transport: any TelegramTransport
  private let turnRunner: any TurnDispatching
  private let logger: Logger

  public init(
    processed: any ProcessedUpdateStore,
    sessionMessages: any SessionMessageStore,
    accessControl: AccessControl,
    transport: any TelegramTransport,
    turnRunner: any TurnDispatching,
    logger: Logger
  ) {
    self.processed = processed
    self.sessionMessages = sessionMessages
    self.accessControl = accessControl
    self.transport = transport
    self.turnRunner = turnRunner
    self.logger = logger
  }

  static let welcomeText = "Hi! I'm online. Send me a message and I'll do my best to help."
  static let privateBotText = "Sorry, this is a private bot."

  @discardableResult
  public func handle(rawUpdate: RawUpdate) async -> HandleOutcome {
    guard let message = IncomingMessage.normalize(from: rawUpdate) else {
      logger.debug("update \(rawUpdate.updateId) has nothing actionable, skipping")
      return .skipped
    }

    let isAllowed = accessControl.isAllowed(userId: message.userId)

    switch message.content {
    case .text(let text) where Self.isStart(text):
      // Onboarding stays a direct reply for both tiers: the owner gets the welcome; a stranger gets
      // THEIR own id to request access (never the allowlist, never a turn).
      let reply = isAllowed ? Self.welcomeText : Self.unauthorizedStartText(userId: message.userId)
      return await sendCanned(
        rawUpdate: rawUpdate,
        chatId: message.chatId,
        text: reply
      )
    case .text(let text):
      guard isAllowed else {
        return await sendCanned(
          rawUpdate: rawUpdate,
          chatId: message.chatId,
          text: Self.privateBotText
        )
      }
      return await dispatchTurn(
        rawUpdate: rawUpdate,
        message: message,
        text: text
      )
    case .unsupported(let kind):
      // Never reveal capabilities to a stranger; the owner gets a specific "can't read X yet".
      let reply = isAllowed ? "I can't read \(kind) yet." : Self.privateBotText
      return await sendCanned(rawUpdate: rawUpdate, chatId: message.chatId, text: reply)
    }
  }

  /// The real §4 turn path: fuse claim+persist in one write, then dispatch the run. A full disk on
  /// either the persist or the run's first write surfaces as the storage-full path; every other run
  /// error is already degraded in-band (the reply is enqueued), so it's logged and swallowed — the
  /// update is durably claimed, so re-polling it would only redeliver a duplicate.
  private func dispatchTurn(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    text: String
  ) async -> HandleOutcome {
    let inbound = InboundMessage(
      updateId: rawUpdate.updateId,
      sessionKey: SessionKey.telegramDM(chatId: message.chatId),
      chatId: message.chatId,
      userId: message.userId,
      text: text,
      isEdited: message.isEdited,
      ts: Date()
    )

    let claim: ClaimResult
    do {
      claim = try sessionMessages.claimAndPersistInbound(inbound)
    } catch StoreError.diskFull {
      return await storageFull(chatId: message.chatId)
    } catch {
      logger.error("persist failed for update \(rawUpdate.updateId): \(error)")
      return .transientFailure
    }

    guard claim.newlyClaimed, let sessionId = claim.sessionId else {
      logger.debug("duplicate update \(rawUpdate.updateId), skipping")
      return .skipped
    }

    do {
      try await turnRunner.run(sessionId: sessionId, chatId: message.chatId)
    } catch StoreError.diskFull {
      return await storageFull(chatId: message.chatId)
    } catch {
      // The run degrades every other failure in-band (reply already enqueued), so there's nothing
      // to recover here; the claimed update should still advance.
      logger.error("turn run error (handled in-band) for update \(rawUpdate.updateId): \(error)")
    }

    return .processed
  }

  /// A direct canned reply, deduped via `claimUpdate` so a redelivery doesn't double-send it.
  private func sendCanned(
    rawUpdate: RawUpdate,
    chatId: Int64,
    text: String
  ) async -> HandleOutcome {
    let claimed: Bool
    do {
      claimed = try processed.claimUpdate(updateId: rawUpdate.updateId)
    } catch StoreError.diskFull {
      return await storageFull(chatId: chatId)
    } catch {
      logger.error("claim failed for update \(rawUpdate.updateId): \(error)")
      return .transientFailure
    }

    guard claimed else {
      logger.debug("duplicate update \(rawUpdate.updateId), skipping")
      return .skipped
    }

    do {
      _ = try await transport.sendMessage(chatId: chatId, text: text)
    } catch {
      logger.error("send failed for update \(rawUpdate.updateId): \(error)")
      return .transientFailure
    }

    return .processed
  }

  /// Best-effort "storage full" notice (the send may still succeed — a full disk doesn't break the
  /// network) and the signal for the poller to back off without advancing the offset (F23).
  private func storageFull(chatId: Int64) async -> HandleOutcome {
    do {
      _ = try await transport.sendMessage(chatId: chatId, text: Degradation.storageFull)
    } catch {
      logger.error("failed to send storage-full notice: \(error)")
    }
    return .storageFull
  }

  private static func unauthorizedStartText(userId: Int64) -> String {
    """
    This is a private bot. Your Telegram user ID is \(userId). Ask the owner to add it to the allowlist.
    """
  }

  private static func isStart(_ text: String) -> Bool {
    text == "/start" || text.hasPrefix("/start ") || text.hasPrefix("/start@")
  }
}
