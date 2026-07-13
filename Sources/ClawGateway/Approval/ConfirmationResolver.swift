import ClawCore
import Foundation
import Logging

/// Intercepts plain text while a confirmation is parked for the session. The session
/// lookup is read-only and fails closed: with the lookup down we cannot prove whether a parked
/// "yes" should be intercepted, so nothing is claimed and the update is retried instead.
struct ConfirmationResolver: Sendable {
  let sessionMessages: any SessionMessageStore
  let pendingConfirmations: PendingConfirmationRegistry
  let memoryCommands: any MemoryCommandStore

  let schedule: ScheduleSurface
  let replies: ReplySender

  let now: @Sendable () -> Date

  let logger: Logger

  /// nil ⇒ nothing to resolve; the caller falls through to normal turn dispatch.
  func resolve(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    text: String
  ) async throws(RoutingHalt) -> HandleOutcome? {
    let existing = try await replies.perform(
      "pending lookup",
      updateId: rawUpdate.updateId,
      chatId: message.chatId
    ) {
      try sessionMessages.findSession(sessionKey: SessionKey.telegramDM(chatId: message.chatId))
    }
    guard let sessionId = existing else {
      return nil
    }

    guard let entry = await pendingConfirmations.pending(sessionId: sessionId) else {
      return nil
    }

    guard case .command(let confirmation) = entry else {
      return nil
    }

    switch ConfirmationReply.parse(text) {
    case .confirm:
      return try await commitPending(
        confirmation,
        sessionId: sessionId,
        rawUpdate: rawUpdate,
        message: message
      )
    case .cancel:
      return try await cancelPending(
        sessionId: sessionId,
        rawUpdate: rawUpdate,
        message: message
      )
    case .other:
      await pendingConfirmations.clear(sessionId: sessionId)
      return nil
    }
  }
}

// MARK: - Commit & Cancel

private extension ConfirmationResolver {
  /// Confirms a parked effect through its atomic claim+effect+audit store seam.
  func commitPending(
    _ confirmation: CommandConfirmation,
    sessionId: Int64,
    rawUpdate: RawUpdate,
    message: IncomingMessage
  ) async throws(RoutingHalt) -> HandleOutcome {
    // A parked schedule can be confirmed long after its preview; recompute the fire time from
    // the parked rule against the arm-time clock (details in OccurrencePolicy.armOccurrence).
    // A one-shot whose instant has passed cannot be salvaged — reject it so the owner
    // reschedules rather than arming a job that silently never fires.
    var scheduleArmNext: Date?
    if case .scheduleArm(let validated) = confirmation {
      guard let recomputed = schedule.policy.armOccurrence(for: validated, at: now()) else {
        return try await rejectStaleArm(
          sessionId: sessionId,
          rawUpdate: rawUpdate,
          message: message
        )
      }
      scheduleArmNext = recomputed
    }

    let newlyClaimed: Bool
    let ackText: String
    do {
      (newlyClaimed, ackText) = try applyConfirmedEffect(
        confirmation,
        updateId: rawUpdate.updateId,
        chatId: message.chatId,
        scheduleArmNext: scheduleArmNext
      )
    } catch StoreError.diskFull {
      throw RoutingHalt(outcome: await replies.storageFull(chatId: message.chatId))
    } catch {
      // A non-disk commit failure is terminal for the parked entry — recovery is claim + clear
      // + per-entry ack, which `perform`'s retry/ack options don't express.
      logger.error("confirmation commit failed for update \(rawUpdate.updateId): \(error)")
      return try await failPendingCommit(
        confirmation,
        sessionId: sessionId,
        rawUpdate: rawUpdate,
        message: message
      )
    }

    guard newlyClaimed else {
      return replies.skipDuplicate(updateId: rawUpdate.updateId)
    }

    await pendingConfirmations.clear(sessionId: sessionId)

    return await replies.sendCommandAck(
      updateId: rawUpdate.updateId,
      chatId: message.chatId,
      text: ackText
    )
  }

  /// Applies the parked effect through its atomic claim+effect+audit store seam and returns the
  /// claim verdict plus the per-effect ack text. Store failures propagate to `commitPending`.
  func applyConfirmedEffect(
    _ confirmation: CommandConfirmation,
    updateId: Int64,
    chatId: Int64,
    scheduleArmNext: Date?
  ) throws -> (newlyClaimed: Bool, ackText: String) {
    switch confirmation {
    case .rememberWrite(let request):
      let result = try memoryCommands.applyRemember(
        updateId: updateId,
        item: request.item,
        now: now()
      )
      return (result.newlyClaimed, MemoryReplies.saved(id: result.item?.id))
    case .deleteItem(let itemId):
      let result = try memoryCommands.applyForget(
        updateId: updateId,
        itemId: itemId,
        now: now()
      )
      return (result.newlyClaimed, MemoryReplies.deleted(id: itemId))
    case .scheduleArm(let validated):
      // owner_chat_id is set HERE, in code, from the arming chat — never model- or
      // prompt-controlled. The insert is the exact parked draft (no re-parse).
      let newJob = NewScheduledJob(
        ownerChatId: chatId,
        label: validated.label,
        prompt: validated.prompt,
        recurrence: validated.recurrence,
        timezone: validated.timezone,
        nextOccurrence: scheduleArmNext ?? validated.firstOccurrence
      )
      let result = try schedule.commands.applyArm(
        updateId: updateId,
        job: newJob,
        now: now()
      )
      return (result.newlyClaimed, ScheduleReplies.armed(job: result.job))
    }
  }

  /// A parked schedule confirmed after its only fire time has passed: nothing valid remains to
  /// arm. Claim the update (dedup), clear the slot, and tell the owner to reschedule.
  func rejectStaleArm(
    sessionId: Int64,
    rawUpdate: RawUpdate,
    message: IncomingMessage
  ) async throws(RoutingHalt) -> HandleOutcome {
    try await replies.claimUpdate(updateId: rawUpdate.updateId, chatId: message.chatId)

    await pendingConfirmations.clear(sessionId: sessionId)

    return await replies.sendCommandAck(
      updateId: rawUpdate.updateId,
      chatId: message.chatId,
      text: ScheduleReplies.armExpired
    )
  }

  /// A non-disk commit failure is terminal for the parked entry: claim the update, clear the
  /// ephemeral pending state, and tell the owner nothing changed so they can re-issue.
  func failPendingCommit(
    _ confirmation: CommandConfirmation,
    sessionId: Int64,
    rawUpdate: RawUpdate,
    message: IncomingMessage
  ) async throws(RoutingHalt) -> HandleOutcome {
    try await replies.claimUpdate(updateId: rawUpdate.updateId, chatId: message.chatId)

    await pendingConfirmations.clear(sessionId: sessionId)

    let errorText: String =
      switch confirmation {
      case .rememberWrite:
        MemoryReplies.saveFailed
      case .deleteItem:
        MemoryReplies.deleteFailed
      case .scheduleArm:
        ScheduleReplies.armFailed
      }

    return await replies.sendCommandAck(
      updateId: rawUpdate.updateId,
      chatId: message.chatId,
      text: errorText
    )
  }

  /// A negative confirmation claims the update, clears the parked entry, and sends a cancel ack.
  func cancelPending(
    sessionId: Int64,
    rawUpdate: RawUpdate,
    message: IncomingMessage
  ) async throws(RoutingHalt) -> HandleOutcome {
    try await replies.claimUpdate(updateId: rawUpdate.updateId, chatId: message.chatId)

    await pendingConfirmations.clear(sessionId: sessionId)

    return await replies.sendCommandAck(
      updateId: rawUpdate.updateId,
      chatId: message.chatId,
      text: MemoryReplies.cancelled
    )
  }
}
