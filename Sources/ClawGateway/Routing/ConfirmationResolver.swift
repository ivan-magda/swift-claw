import ClawCore
import Foundation
import Logging

/// Intercepts plain text while a confirmation is parked for the session (§9/§14). The session
/// lookup is read-only and fails closed: with the lookup down we cannot prove whether a parked
/// "yes" should be intercepted, so nothing is claimed and the update is retried instead.
struct ConfirmationResolver: Sendable {
  let sessionMessages: any SessionMessageStore
  let pendingConfirmations: PendingConfirmationRegistry
  let memoryCommands: any MemoryCommandStore
  let schedule: ScheduleSurface
  let turnDispatch: TurnDispatch
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

    // A tool approval differs from the memory-confirm flow: BOTH a confirm and a non-confirm
    // reply become an ordinary persisted turn (never a command ack, §14).
    if case .toolApproval(let request) = entry {
      await pendingConfirmations.clear(sessionId: sessionId)
      let grant: OneTurnGrant? =
        ConfirmationReply.parse(text) == .confirm
        ? OneTurnGrant(action: request.action)
        : nil
      return try await turnDispatch.dispatch(
        rawUpdate: rawUpdate,
        message: message,
        text: text,
        grant: grant
      )
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
      switch confirmation {
      case .rememberWrite(let request):
        let result = try memoryCommands.applyRemember(
          updateId: rawUpdate.updateId,
          item: request.item,
          now: now()
        )
        newlyClaimed = result.newlyClaimed
        ackText = MemoryReplies.saved(id: result.item?.id)
      case .deleteItem(let itemId):
        let result = try memoryCommands.applyForget(
          updateId: rawUpdate.updateId,
          itemId: itemId,
          now: now()
        )
        newlyClaimed = result.newlyClaimed
        ackText = MemoryReplies.deleted(id: itemId)
      case .scheduleArm(let validated):
        // owner_chat_id is set HERE, in code, from the arming chat — never model- or
        // prompt-controlled (spec §4.1). The insert is the exact parked draft (§8, no re-parse).
        let newJob = NewScheduledJob(
          ownerChatId: message.chatId,
          label: validated.label,
          prompt: validated.prompt,
          recurrence: validated.recurrence,
          timezone: validated.timezone,
          nextOccurrence: scheduleArmNext ?? validated.firstOccurrence
        )
        let result = try schedule.commands.applyArm(
          updateId: rawUpdate.updateId,
          job: newJob,
          now: now()
        )
        newlyClaimed = result.newlyClaimed
        ackText = ScheduleReplies.armed(job: result.job)
      }
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

    let errorText: String
    switch confirmation {
    case .rememberWrite:
      errorText = MemoryReplies.saveFailed
    case .deleteItem:
      errorText = MemoryReplies.deleteFailed
    case .scheduleArm:
      errorText = ScheduleReplies.armFailed
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
