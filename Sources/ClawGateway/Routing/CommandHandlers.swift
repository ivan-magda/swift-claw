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

  let coordinator: ApprovalCoordinator

  func stop(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    mode: ChatMode = .direct
  ) async throws(RoutingHalt) -> HandleOutcome {
    let result = try await replies.perform(
      "stop command",
      updateID: rawUpdate.updateID,
      target: .reply(to: message, mode: mode)
    ) {
      try commands.applyStop(
        updateID: rawUpdate.updateID,
        sessionKey: SessionKey.telegram(for: message, mode: mode),
        now: now()
      )
    }

    guard result.newlyClaimed else {
      return replies.skipDuplicate(updateID: rawUpdate.updateID)
    }

    // Signal the coordinator BEFORE cancelling the lane. Cancelling first would race the parked
    // waiter: `lane.cancel` cancels the very Task suspended in `ApprovalWaiter.park`, whose
    // `awaitResolution` cancellation path resumes the waiter with `nil` — if that wins the race
    // against this signal, `park` returns early and never fills the synthetic observation, leaving
    // a dangling tool_call on the now-terminal run. Signalling first delivers a real `.denied` to
    // the still-registered waiter, and there is no suspension point between its resume and the
    // synchronous observation-fill write, so the subsequent cancel can only no-op an already
    // resumed task. (Deliberate deviation from the plan's literal Step 13 ordering.)
    for approvalID in result.resolvedApprovalIDs {
      await coordinator.signal(.denied(.cancelled), forApprovalID: approvalID)
    }

    for runID in result.cancelledRunIDs {
      await lanes.cancel(runID: runID)
    }

    let reply =
      result.cancelledRunIDs.isEmpty ? CommandReplies.nothingToStop : CommandReplies.stopped
    return await replies.sendCommandAck(
      updateID: rawUpdate.updateID,
      target: .reply(to: message, mode: mode),
      text: reply
    )
  }

  func new(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    mode: ChatMode = .direct
  ) async throws(RoutingHalt) -> HandleOutcome {
    let result = try await replies.perform(
      "new command",
      updateID: rawUpdate.updateID,
      target: .reply(to: message, mode: mode)
    ) {
      try commands.applyNew(
        updateID: rawUpdate.updateID,
        sessionKey: SessionKey.telegram(for: message, mode: mode),
        now: now()
      )
    }

    guard result.newlyClaimed else {
      return replies.skipDuplicate(updateID: rawUpdate.updateID)
    }

    // Signal the coordinator BEFORE cancelling the lane — same race as `/stop` (see `stop`):
    // cancelling first can let the parked waiter's `nil`-resume win over this signal, so `park`
    // exits without filling the synthetic observation. Signalling first delivers a real
    // `.superseded` to the still-registered waiter, whose observation-fill write then runs before
    // the cancel can interrupt it. (Deliberate deviation from the plan's literal Step 13 ordering.)
    for approvalID in result.resolvedApprovalIDs {
      await coordinator.signal(.denied(.superseded), forApprovalID: approvalID)
    }

    if let sessionID = result.sessionID {
      await lanes.cancelAll(sessionID: sessionID)
      await pendingConfirmations.clear(sessionID: sessionID)
    }

    return await replies.sendCommandAck(
      updateID: rawUpdate.updateID,
      target: .reply(to: message, mode: mode),
      text: CommandReplies.freshConversation
    )
  }

  /// `/remember` is handled directly: claim the update, resolve the session, build the pure write
  /// request, park it, and send the confirm prompt. No durable memory row is written until the
  /// owner confirms.
  func remember(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    command: RememberCommand,
    mode: ChatMode = .direct
  ) async throws(RoutingHalt) -> HandleOutcome {
    guard case .save(let kind, let text) = command else {
      return await replies.sendCanned(
        updateID: rawUpdate.updateID,
        target: .reply(to: message, mode: mode),
        text: MemoryReplies.rememberUsage
      )
    }

    let claim = try await replies.perform(
      "remember claim",
      updateID: rawUpdate.updateID,
      target: .reply(to: message, mode: mode)
    ) {
      try sessionMessages.claimCommandUpdate(
        updateID: rawUpdate.updateID,
        sessionKey: SessionKey.telegram(for: message, mode: mode),
        now: now()
      )
    }

    guard case .claimed(let sessionID) = claim else {
      return replies.skipDuplicate(updateID: rawUpdate.updateID)
    }

    let request: MemoryWriteRequest
    do {
      request = try MemoryWriteBuilder.build(rawText: text, kind: kind, sessionID: sessionID)
    } catch {
      return await replies.sendCommandAck(
        updateID: rawUpdate.updateID,
        target: .reply(to: message, mode: mode),
        text: MemoryReplies.nothingToSave
      )
    }

    await pendingConfirmations.park(.rememberWrite(request), sessionID: sessionID)

    return await replies.sendCommandAck(
      updateID: rawUpdate.updateID,
      target: .reply(to: message, mode: mode),
      text: request.confirmationText
    )
  }

  func memory(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    command: MemoryCommand,
    mode: ChatMode = .direct
  ) async throws(RoutingHalt) -> HandleOutcome {
    let target = DeliveryTarget.reply(to: message, mode: mode)
    return switch command {
    case .review:
      try await memoryReview(rawUpdate: rawUpdate, target: target, kind: nil)
    case .filter(let kind):
      try await memoryReview(rawUpdate: rawUpdate, target: target, kind: kind)
    case .show(let id):
      try await memoryShow(rawUpdate: rawUpdate, target: target, id: id)
    case .delete(let id):
      try await memoryDelete(
        rawUpdate: rawUpdate,
        target: target,
        sessionKey: SessionKey.telegram(for: message, mode: mode),
        id: id
      )
    case .invalid:
      await replies.sendCanned(
        updateID: rawUpdate.updateID,
        target: .reply(to: message, mode: mode),
        text: MemoryReplies.memoryUsage
      )
    }
  }
}

// MARK: - Memory Commands

private extension CommandHandlers {
  func memoryReview(
    rawUpdate: RawUpdate,
    target: DeliveryTarget,
    kind: MemoryKind?
  ) async throws(RoutingHalt) -> HandleOutcome {
    let items = try await replies.perform(
      "memory review",
      updateID: rawUpdate.updateID,
      target: target
    ) {
      try memory.list(kind: kind, limit: MemoryReplies.reviewListLimit)
    }

    let text =
      items.isEmpty ? MemoryReplies.emptyReview(kind: kind) : MemoryReplies.reviewList(items: items)

    return await replies.sendCanned(updateID: rawUpdate.updateID, target: target, text: text)
  }

  func memoryShow(
    rawUpdate: RawUpdate,
    target: DeliveryTarget,
    id: Int64
  ) async throws(RoutingHalt) -> HandleOutcome {
    let item = try await replies.perform(
      "memory show",
      updateID: rawUpdate.updateID,
      target: target
    ) {
      try memory.get(id: id)
    }

    let text = item.map(MemoryReplies.showItem) ?? MemoryReplies.notFound(id: id)
    return await replies.sendCanned(updateID: rawUpdate.updateID, target: target, text: text)
  }

  func memoryDelete(
    rawUpdate: RawUpdate,
    target: DeliveryTarget,
    sessionKey: String,
    id: Int64
  ) async throws(RoutingHalt) -> HandleOutcome {
    let existing = try await replies.perform(
      "memory delete lookup",
      updateID: rawUpdate.updateID,
      target: target
    ) {
      try memory.get(id: id)
    }

    guard let item = existing else {
      return await replies.sendCanned(
        updateID: rawUpdate.updateID,
        target: target,
        text: MemoryReplies.notFound(id: id)
      )
    }

    let claim = try await replies.perform(
      "memory delete claim",
      updateID: rawUpdate.updateID,
      target: target
    ) {
      try sessionMessages.claimCommandUpdate(
        updateID: rawUpdate.updateID,
        sessionKey: sessionKey,
        now: now()
      )
    }

    guard case .claimed(let sessionID) = claim else {
      return replies.skipDuplicate(updateID: rawUpdate.updateID)
    }

    await pendingConfirmations.park(.deleteItem(id: id), sessionID: sessionID)

    return await replies.sendCommandAck(
      updateID: rawUpdate.updateID,
      target: target,
      text: MemoryReplies.deleteConfirmPrompt(item: item)
    )
  }
}
