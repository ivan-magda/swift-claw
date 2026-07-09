import ClawAgent
import ClawCore
import Foundation
import Logging

/// The session and memory command family: /stop, /new, /remember, /memory. Every effect claims
/// its update through a fused store seam or parks a confirmation; nothing here dispatches turns.
struct CommandHandlers: Sendable {
  let commands: any CommandStore
  let sessionMessages: any SessionMessageStore
  let memory: any MemoryStore
  let pendingConfirmations: PendingConfirmationRegistry
  let lanes: SessionLaneRegistry
  let replies: ReplySender
  let now: @Sendable () -> Date
  let logger: Logger
  let coordinator: ApprovalCoordinator

  func stop(
    rawUpdate: RawUpdate,
    message: IncomingMessage
  ) async throws(RoutingHalt) -> HandleOutcome {
    let result = try await replies.perform(
      "stop command",
      updateId: rawUpdate.updateId,
      chatId: message.chatId
    ) {
      try commands.applyStop(
        updateId: rawUpdate.updateId,
        sessionKey: SessionKey.telegramDM(chatId: message.chatId),
        now: now()
      )
    }

    guard result.newlyClaimed else {
      return replies.skipDuplicate(updateId: rawUpdate.updateId)
    }

    if let sessionId = result.sessionId, result.cancelledRunIds.isEmpty == false {
      let lane = await lanes.actor(for: sessionId)
      for runId in result.cancelledRunIds {
        await lane.cancel(runId: runId)
      }
    }

    for approvalId in result.resolvedApprovalIds {
      await coordinator.signal(approvalId: approvalId, .denied(.cancelled))
    }

    let reply =
      result.cancelledRunIds.isEmpty ? CommandReplies.nothingToStop : CommandReplies.stopped
    return await replies.sendCommandAck(
      updateId: rawUpdate.updateId,
      chatId: message.chatId,
      text: reply
    )
  }

  func new(
    rawUpdate: RawUpdate,
    message: IncomingMessage
  ) async throws(RoutingHalt) -> HandleOutcome {
    let result = try await replies.perform(
      "new command",
      updateId: rawUpdate.updateId,
      chatId: message.chatId
    ) {
      try commands.applyNew(
        updateId: rawUpdate.updateId,
        sessionKey: SessionKey.telegramDM(chatId: message.chatId),
        now: now()
      )
    }

    guard result.newlyClaimed else {
      return replies.skipDuplicate(updateId: rawUpdate.updateId)
    }

    if let sessionId = result.sessionId {
      let lane = await lanes.actor(for: sessionId)
      await lane.cancelAll()
      await pendingConfirmations.clear(sessionId: sessionId)
    }

    for approvalId in result.resolvedApprovalIds {
      await coordinator.signal(approvalId: approvalId, .denied(.superseded))
    }

    return await replies.sendCommandAck(
      updateId: rawUpdate.updateId,
      chatId: message.chatId,
      text: CommandReplies.freshConversation
    )
  }

  /// `/remember` is handled directly: claim the update, resolve the session, build the pure write
  /// request, park it, and send the confirm prompt. No durable memory row is written until the
  /// owner confirms.
  func remember(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    command: RememberCommand
  ) async throws(RoutingHalt) -> HandleOutcome {
    guard case .save(let kind, let text) = command else {
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        chatId: message.chatId,
        text: MemoryReplies.rememberUsage
      )
    }

    let claim = try await replies.perform(
      "remember claim",
      updateId: rawUpdate.updateId,
      chatId: message.chatId
    ) {
      try sessionMessages.claimCommandUpdate(
        updateId: rawUpdate.updateId,
        sessionKey: SessionKey.telegramDM(chatId: message.chatId),
        now: now()
      )
    }

    guard case .claimed(let sessionId) = claim else {
      return replies.skipDuplicate(updateId: rawUpdate.updateId)
    }

    let request: MemoryWriteRequest
    do {
      request = try MemoryWriteBuilder.build(rawText: text, kind: kind, sessionId: sessionId)
    } catch {
      return await replies.sendCommandAck(
        updateId: rawUpdate.updateId,
        chatId: message.chatId,
        text: MemoryReplies.nothingToSave
      )
    }

    await pendingConfirmations.park(.command(.rememberWrite(request)), sessionId: sessionId)

    return await replies.sendCommandAck(
      updateId: rawUpdate.updateId,
      chatId: message.chatId,
      text: request.confirmationText
    )
  }

  func memory(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    command: MemoryCommand
  ) async throws(RoutingHalt) -> HandleOutcome {
    switch command {
    case .review:
      try await memoryReview(rawUpdate: rawUpdate, chatId: message.chatId, kind: nil)
    case .filter(let kind):
      try await memoryReview(rawUpdate: rawUpdate, chatId: message.chatId, kind: kind)
    case .show(let id):
      try await memoryShow(rawUpdate: rawUpdate, chatId: message.chatId, id: id)
    case .delete(let id):
      try await memoryDelete(rawUpdate: rawUpdate, chatId: message.chatId, id: id)
    case .invalid:
      await replies.sendCanned(
        updateId: rawUpdate.updateId,
        chatId: message.chatId,
        text: MemoryReplies.memoryUsage
      )
    }
  }
}

// MARK: - Memory Commands

private extension CommandHandlers {
  func memoryReview(
    rawUpdate: RawUpdate,
    chatId: Int64,
    kind: MemoryKind?
  ) async throws(RoutingHalt) -> HandleOutcome {
    let items = try await replies.perform(
      "memory review",
      updateId: rawUpdate.updateId,
      chatId: chatId
    ) {
      try memory.list(kind: kind, limit: MemoryReplies.reviewListLimit)
    }

    let text =
      items.isEmpty
      ? MemoryReplies.emptyReview(kind: kind)
      : MemoryReplies.reviewList(items: items)

    return await replies.sendCanned(updateId: rawUpdate.updateId, chatId: chatId, text: text)
  }

  func memoryShow(
    rawUpdate: RawUpdate,
    chatId: Int64,
    id: Int64
  ) async throws(RoutingHalt) -> HandleOutcome {
    let item = try await replies.perform(
      "memory show",
      updateId: rawUpdate.updateId,
      chatId: chatId
    ) {
      try memory.get(id: id)
    }

    let text = item.map(MemoryReplies.showItem) ?? MemoryReplies.notFound(id: id)
    return await replies.sendCanned(updateId: rawUpdate.updateId, chatId: chatId, text: text)
  }

  func memoryDelete(
    rawUpdate: RawUpdate,
    chatId: Int64,
    id: Int64
  ) async throws(RoutingHalt) -> HandleOutcome {
    let existing = try await replies.perform(
      "memory delete lookup",
      updateId: rawUpdate.updateId,
      chatId: chatId
    ) {
      try memory.get(id: id)
    }

    guard let item = existing else {
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        chatId: chatId,
        text: MemoryReplies.notFound(id: id)
      )
    }

    let claim = try await replies.perform(
      "memory delete claim",
      updateId: rawUpdate.updateId,
      chatId: chatId
    ) {
      try sessionMessages.claimCommandUpdate(
        updateId: rawUpdate.updateId,
        sessionKey: SessionKey.telegramDM(chatId: chatId),
        now: now()
      )
    }

    guard case .claimed(let sessionId) = claim else {
      return replies.skipDuplicate(updateId: rawUpdate.updateId)
    }

    await pendingConfirmations.park(.command(.deleteItem(id: id)), sessionId: sessionId)

    return await replies.sendCommandAck(
      updateId: rawUpdate.updateId,
      chatId: chatId,
      text: MemoryReplies.deleteConfirmPrompt(item: item)
    )
  }
}
