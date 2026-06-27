import ClawAgent
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
  private let commands: any CommandStore
  private let botUsername: String?
  private let accessControl: AccessControl
  private let transport: any TelegramTransport
  private let turnRunner: any TurnDispatching
  private let lanes: SessionLaneRegistry
  private let logger: Logger

  public init(
    processed: any ProcessedUpdateStore,
    sessionMessages: any SessionMessageStore,
    commands: any CommandStore,
    botUsername: String?,
    accessControl: AccessControl,
    transport: any TelegramTransport,
    turnRunner: any TurnDispatching,
    lanes: SessionLaneRegistry,
    logger: Logger
  ) {
    self.processed = processed
    self.sessionMessages = sessionMessages
    self.commands = commands
    self.botUsername = botUsername
    self.accessControl = accessControl
    self.transport = transport
    self.turnRunner = turnRunner
    self.lanes = lanes
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
    case .text(let text):
      switch Command.parse(text, botUsername: botUsername) {
      case .start:
        // Onboarding stays a direct reply for both tiers: the owner gets the welcome; a stranger
        // gets THEIR own id to request access (never the allowlist, never a turn).
        let reply =
          isAllowed ? Self.welcomeText : Self.unauthorizedStartText(userId: message.userId)
        return await sendCanned(
          rawUpdate: rawUpdate,
          chatId: message.chatId,
          text: reply
        )
      case .stop:
        guard isAllowed else {
          return await sendCanned(
            rawUpdate: rawUpdate,
            chatId: message.chatId,
            text: Self.privateBotText
          )
        }
        return await handleStop(rawUpdate: rawUpdate, message: message)
      case .new:
        guard isAllowed else {
          return await sendCanned(
            rawUpdate: rawUpdate,
            chatId: message.chatId,
            text: Self.privateBotText
          )
        }
        return await handleNew(rawUpdate: rawUpdate, message: message)
      case .plain(let plainText):
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
          text: plainText
        )
      }
    case .unsupported(let kind):
      // Never reveal capabilities to a stranger; the owner gets a specific "can't read X yet".
      let reply = isAllowed ? "I can't read \(kind) yet." : Self.privateBotText
      return await sendCanned(rawUpdate: rawUpdate, chatId: message.chatId, text: reply)
    }
  }

  private func handleStop(rawUpdate: RawUpdate, message: IncomingMessage) async -> HandleOutcome {
    let result: StopCommandResult
    do {
      result = try commands.applyStop(
        updateId: rawUpdate.updateId,
        sessionKey: SessionKey.telegramDM(chatId: message.chatId),
        now: Date()
      )
    } catch StoreError.diskFull {
      return await storageFull(chatId: message.chatId)
    } catch {
      logger.error("stop command failed for update \(rawUpdate.updateId): \(error)")
      return .transientFailure
    }

    guard result.newlyClaimed else {
      logger.debug("duplicate update \(rawUpdate.updateId), skipping")
      return .skipped
    }

    if let sessionId = result.sessionId, let runId = result.cancelledRunId {
      let lane = await lanes.actor(for: sessionId)
      await lane.cancel(runId: runId)
    }

    let reply = result.cancelledRunId == nil ? CommandReplies.nothingToStop : CommandReplies.stopped
    return await sendCommandAck(rawUpdate: rawUpdate, chatId: message.chatId, text: reply)
  }

  private func handleNew(rawUpdate: RawUpdate, message: IncomingMessage) async -> HandleOutcome {
    let result: NewCommandResult
    do {
      result = try commands.applyNew(
        updateId: rawUpdate.updateId,
        sessionKey: SessionKey.telegramDM(chatId: message.chatId),
        now: Date()
      )
    } catch StoreError.diskFull {
      return await storageFull(chatId: message.chatId)
    } catch {
      logger.error("new command failed for update \(rawUpdate.updateId): \(error)")
      return .transientFailure
    }

    guard result.newlyClaimed else {
      logger.debug("duplicate update \(rawUpdate.updateId), skipping")
      return .skipped
    }

    if let sessionId = result.sessionId {
      let lane = await lanes.actor(for: sessionId)
      await lane.cancelAll()
    }

    return await sendCommandAck(
      rawUpdate: rawUpdate,
      chatId: message.chatId,
      text: CommandReplies.freshConversation
    )
  }

  /// Fuses claim + persistence, then enqueues the durable run and returns without awaiting it.
  /// Persistence failure prevents cursor advancement; background turn failures are logged in-band.
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

    guard
      claim.newlyClaimed,
      let sessionId = claim.sessionId,
      let runId = claim.runId,
      let triggerMessageId = claim.triggerMessageId
    else {
      logger.debug("duplicate update \(rawUpdate.updateId), skipping")
      return .skipped
    }

    let lane = await lanes.actor(for: sessionId)
    await lane.enqueue(runId: runId) { [turnRunner, logger] in
      do {
        try await turnRunner.run(
          runId: runId,
          sessionId: sessionId,
          chatId: message.chatId,
          triggerMessageId: triggerMessageId
        )
      } catch StoreError.diskFull {
        logger.error("turn \(runId) stopped by storage full after enqueue")
      } catch {
        logger.error("turn run error (handled in-band) for update \(rawUpdate.updateId): \(error)")
      }
    }

    return .processed
  }

  private func sendCommandAck(
    rawUpdate: RawUpdate,
    chatId: Int64,
    text: String
  ) async -> HandleOutcome {
    do {
      _ = try await transport.sendMessage(chatId: chatId, text: text)
    } catch {
      logger.error("command ack send failed for update \(rawUpdate.updateId): \(error)")
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
}
