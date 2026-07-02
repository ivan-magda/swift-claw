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
/// `/start`, `/remember`, unauthorized senders, unsupported media — gets a direct canned reply or
/// command ack. Memory commands (`/remember`, `/memory`) are handled directly too, and while a
/// confirmation is parked for a session, the next plain text resolves it here before any turn is
/// dispatched. The two dedup paths share the `processed_updates` key space, and each update takes
/// exactly one path, so an update is claimed once.
public struct MessageRouter: Sendable {
  private let processed: any ProcessedUpdateStore
  private let sessionMessages: any SessionMessageStore
  private let commands: any CommandStore
  private let memory: any MemoryStore
  private let memoryCommands: any MemoryCommandStore
  private let pendingConfirmations: PendingConfirmationRegistry
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
    memory: any MemoryStore,
    memoryCommands: any MemoryCommandStore,
    pendingConfirmations: PendingConfirmationRegistry,
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
    self.memory = memory
    self.memoryCommands = memoryCommands
    self.pendingConfirmations = pendingConfirmations
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
          return await sendPrivateBotReply(rawUpdate: rawUpdate, chatId: message.chatId)
        }
        return await handleStop(rawUpdate: rawUpdate, message: message)
      case .new:
        guard isAllowed else {
          return await sendPrivateBotReply(rawUpdate: rawUpdate, chatId: message.chatId)
        }
        return await handleNew(rawUpdate: rawUpdate, message: message)
      case .remember(let rememberCommand):
        guard isAllowed else {
          return await sendPrivateBotReply(rawUpdate: rawUpdate, chatId: message.chatId)
        }
        return await handleRemember(
          rawUpdate: rawUpdate,
          message: message,
          command: rememberCommand
        )
      case .memory(let memoryCommand):
        guard isAllowed else {
          return await sendPrivateBotReply(rawUpdate: rawUpdate, chatId: message.chatId)
        }
        return await handleMemory(
          rawUpdate: rawUpdate,
          message: message,
          command: memoryCommand
        )
      case .plain(let plainText):
        guard isAllowed else {
          return await sendPrivateBotReply(rawUpdate: rawUpdate, chatId: message.chatId)
        }
        if let resolved = await resolvePendingConfirmation(
          rawUpdate: rawUpdate,
          message: message,
          text: plainText
        ) {
          return resolved
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

  private static func unauthorizedStartText(userId: Int64) -> String {
    """
    This is a private bot. Your Telegram user ID is \(userId). Ask the owner to add it to the allowlist.
    """
  }
}

extension MessageRouter {
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

  /// `/remember` is handled directly: claim the update, resolve the session, build the pure write
  /// request, park it, and send the confirm prompt. No durable memory row is written until the
  /// owner confirms.
  private func handleRemember(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    command: RememberCommand
  ) async -> HandleOutcome {
    guard case .save(let kind, let text) = command else {
      return await sendCanned(
        rawUpdate: rawUpdate,
        chatId: message.chatId,
        text: MemoryReplies.rememberUsage
      )
    }

    let claim: CommandClaim
    do {
      claim = try sessionMessages.claimCommandUpdate(
        updateId: rawUpdate.updateId,
        sessionKey: SessionKey.telegramDM(chatId: message.chatId),
        now: Date()
      )
    } catch StoreError.diskFull {
      return await storageFull(chatId: message.chatId)
    } catch {
      logger.error("remember claim failed for update \(rawUpdate.updateId): \(error)")
      return .transientFailure
    }

    guard case .claimed(let sessionId) = claim else {
      logger.debug("duplicate update \(rawUpdate.updateId), skipping")
      return .skipped
    }

    let request: MemoryWriteRequest
    do {
      request = try MemoryWriteBuilder.build(rawText: text, kind: kind, sessionId: sessionId)
    } catch {
      return await sendCommandAck(
        rawUpdate: rawUpdate,
        chatId: message.chatId,
        text: MemoryReplies.nothingToSave
      )
    }

    await pendingConfirmations.park(.rememberWrite(request), sessionId: sessionId)
    return await sendCommandAck(
      rawUpdate: rawUpdate,
      chatId: message.chatId,
      text: request.confirmationText
    )
  }

  private func handleMemory(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    command: MemoryCommand
  ) async -> HandleOutcome {
    switch command {
    case .review:
      return await handleMemoryReview(rawUpdate: rawUpdate, chatId: message.chatId, kind: nil)
    case .filter(let kind):
      return await handleMemoryReview(rawUpdate: rawUpdate, chatId: message.chatId, kind: kind)
    case .show(let id):
      return await handleMemoryShow(rawUpdate: rawUpdate, chatId: message.chatId, id: id)
    case .delete(let id):
      return await handleMemoryDelete(rawUpdate: rawUpdate, chatId: message.chatId, id: id)
    case .invalid:
      return await sendCanned(
        rawUpdate: rawUpdate,
        chatId: message.chatId,
        text: MemoryReplies.memoryUsage
      )
    }
  }

  private func handleMemoryReview(
    rawUpdate: RawUpdate,
    chatId: Int64,
    kind: MemoryKind?
  ) async -> HandleOutcome {
    let items: [MemoryItem]
    do {
      items = try memory.list(kind: kind, limit: MemoryReplies.reviewListLimit)
    } catch StoreError.diskFull {
      return await storageFull(chatId: chatId)
    } catch {
      logger.error("memory review failed for update \(rawUpdate.updateId): \(error)")
      return .transientFailure
    }

    let text =
      items.isEmpty ? MemoryReplies.emptyReview(kind: kind) : MemoryReplies.reviewList(items: items)
    return await sendCanned(rawUpdate: rawUpdate, chatId: chatId, text: text)
  }

  private func handleMemoryShow(
    rawUpdate: RawUpdate,
    chatId: Int64,
    id: Int64
  ) async -> HandleOutcome {
    let item: MemoryItem?
    do {
      item = try memory.get(id: id)
    } catch StoreError.diskFull {
      return await storageFull(chatId: chatId)
    } catch {
      logger.error("memory show failed for update \(rawUpdate.updateId): \(error)")
      return .transientFailure
    }

    let text = item.map(MemoryReplies.showItem) ?? MemoryReplies.notFound(id: id)
    return await sendCanned(rawUpdate: rawUpdate, chatId: chatId, text: text)
  }

  private func handleMemoryDelete(
    rawUpdate: RawUpdate,
    chatId: Int64,
    id: Int64
  ) async -> HandleOutcome {
    let item: MemoryItem
    do {
      guard let existing = try memory.get(id: id) else {
        return await sendCanned(
          rawUpdate: rawUpdate,
          chatId: chatId,
          text: MemoryReplies.notFound(id: id)
        )
      }
      item = existing
    } catch StoreError.diskFull {
      return await storageFull(chatId: chatId)
    } catch {
      logger.error("memory delete lookup failed for update \(rawUpdate.updateId): \(error)")
      return .transientFailure
    }

    let claim: CommandClaim
    do {
      claim = try sessionMessages.claimCommandUpdate(
        updateId: rawUpdate.updateId,
        sessionKey: SessionKey.telegramDM(chatId: chatId),
        now: Date()
      )
    } catch StoreError.diskFull {
      return await storageFull(chatId: chatId)
    } catch {
      logger.error("memory delete claim failed for update \(rawUpdate.updateId): \(error)")
      return .transientFailure
    }

    guard case .claimed(let sessionId) = claim else {
      logger.debug("duplicate update \(rawUpdate.updateId), skipping")
      return .skipped
    }

    await pendingConfirmations.park(.deleteItem(id: id), sessionId: sessionId)
    return await sendCommandAck(
      rawUpdate: rawUpdate,
      chatId: chatId,
      text: MemoryReplies.deleteConfirmPrompt(item: item)
    )
  }

  /// Intercepts plain text while a confirmation is parked for the session. Returns nil when there
  /// is nothing to resolve, so the caller falls through to normal turn dispatch. The session lookup
  /// is read-only and fails closed: with the lookup down we cannot prove whether a parked "yes"
  /// should be intercepted, so nothing is claimed and the update is retried instead.
  private func resolvePendingConfirmation(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    text: String
  ) async -> HandleOutcome? {
    let sessionId: Int64
    do {
      guard
        let existing = try sessionMessages.findSession(
          sessionKey: SessionKey.telegramDM(chatId: message.chatId)
        )
      else {
        return nil
      }
      sessionId = existing
    } catch StoreError.diskFull {
      return await storageFull(chatId: message.chatId)
    } catch {
      logger.error("pending lookup failed for update \(rawUpdate.updateId): \(error)")
      return .transientFailure
    }

    guard let entry = await pendingConfirmations.pending(sessionId: sessionId) else {
      return nil
    }

    switch ConfirmationReply.parse(text) {
    case .confirm:
      return await commitPending(
        entry,
        sessionId: sessionId,
        rawUpdate: rawUpdate,
        message: message
      )
    case .cancel:
      return await cancelPending(
        sessionId: sessionId,
        rawUpdate: rawUpdate,
        message: message
      )
    case .other:
      await pendingConfirmations.clear(sessionId: sessionId)
      return nil
    }
  }

  /// Confirms a parked memory effect through the atomic MemoryCommandStore seam.
  private func commitPending(
    _ entry: PendingConfirmation,
    sessionId: Int64,
    rawUpdate: RawUpdate,
    message: IncomingMessage
  ) async -> HandleOutcome {
    let result: MemoryCommandResult
    let ackText: String
    do {
      switch entry {
      case .rememberWrite(let request):
        result = try memoryCommands.applyRemember(
          updateId: rawUpdate.updateId,
          item: request.item,
          now: Date()
        )
        ackText = MemoryReplies.saved(id: result.item?.id)
      case .deleteItem(let itemId):
        result = try memoryCommands.applyForget(
          updateId: rawUpdate.updateId,
          itemId: itemId,
          now: Date()
        )
        ackText = MemoryReplies.deleted(id: itemId)
      }
    } catch StoreError.diskFull {
      return await storageFull(chatId: message.chatId)
    } catch {
      logger.error("confirmation commit failed for update \(rawUpdate.updateId): \(error)")
      return await failPendingCommit(
        entry,
        sessionId: sessionId,
        rawUpdate: rawUpdate,
        message: message
      )
    }

    guard result.newlyClaimed else {
      logger.debug("duplicate update \(rawUpdate.updateId), skipping")
      return .skipped
    }

    await pendingConfirmations.clear(sessionId: sessionId)
    return await sendCommandAck(rawUpdate: rawUpdate, chatId: message.chatId, text: ackText)
  }

  /// A non-disk commit failure is terminal for the parked entry: claim the update, clear the
  /// ephemeral pending state, and tell the owner nothing changed so they can re-issue the command.
  private func failPendingCommit(
    _ entry: PendingConfirmation,
    sessionId: Int64,
    rawUpdate: RawUpdate,
    message: IncomingMessage
  ) async -> HandleOutcome {
    let claimed: Bool
    do {
      claimed = try processed.claimUpdate(updateId: rawUpdate.updateId)
    } catch StoreError.diskFull {
      return await storageFull(chatId: message.chatId)
    } catch {
      logger.error("failure-claim failed for update \(rawUpdate.updateId): \(error)")
      return .transientFailure
    }

    guard claimed else {
      logger.debug("duplicate update \(rawUpdate.updateId), skipping")
      return .skipped
    }

    await pendingConfirmations.clear(sessionId: sessionId)
    let errorText: String
    switch entry {
    case .rememberWrite:
      errorText = MemoryReplies.saveFailed
    case .deleteItem:
      errorText = MemoryReplies.deleteFailed
    }
    return await sendCommandAck(rawUpdate: rawUpdate, chatId: message.chatId, text: errorText)
  }

  /// A negative confirmation claims the update, clears the parked entry, and sends a cancel ack.
  private func cancelPending(
    sessionId: Int64,
    rawUpdate: RawUpdate,
    message: IncomingMessage
  ) async -> HandleOutcome {
    let claimed: Bool
    do {
      claimed = try processed.claimUpdate(updateId: rawUpdate.updateId)
    } catch StoreError.diskFull {
      return await storageFull(chatId: message.chatId)
    } catch {
      logger.error("cancel claim failed for update \(rawUpdate.updateId): \(error)")
      return .transientFailure
    }

    guard claimed else {
      logger.debug("duplicate update \(rawUpdate.updateId), skipping")
      return .skipped
    }

    await pendingConfirmations.clear(sessionId: sessionId)
    return await sendCommandAck(
      rawUpdate: rawUpdate,
      chatId: message.chatId,
      text: MemoryReplies.cancelled
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

  private func sendPrivateBotReply(rawUpdate: RawUpdate, chatId: Int64) async -> HandleOutcome {
    await sendCanned(rawUpdate: rawUpdate, chatId: chatId, text: Self.privateBotText)
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
}
