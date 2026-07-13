import ClawCore
import Foundation
import Logging

/// The /schedule family: create parses ONE draft and parks it; list is read-only;
/// pause/resume/runnow/cancel claim the update BEFORE their effect so a redelivered command
/// applies once. Occurrence anchoring is `schedule.policy`'s — never recomputed here.
struct ScheduleHandlers: Sendable {
  let schedule: ScheduleSurface

  let sessionMessages: any SessionMessageStore
  let pendingConfirmations: PendingConfirmationRegistry

  let replies: ReplySender
  let enqueuer: TurnEnqueuer

  let now: @Sendable () -> Date
  let logger: Logger

  /// `/schedule <text>`: claim the update, run the ONE parse call, validate
  /// deterministically, park the validated draft, and send the gateway-authored confirm prompt.
  /// Nothing is armed here; every failure is a plain-language reply and parks nothing.
  func create(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    text: String
  ) async throws(RoutingHalt) -> HandleOutcome {
    let claim = try await replies.perform(
      "schedule claim",
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

    switch await schedule.parser.parse(ownerText: text, sessionId: sessionId) {
    case .providerUnavailable:
      // An LLM/API failure degrades exactly like any turn; nothing armed.
      return await replies.sendCommandAck(
        updateId: rawUpdate.updateId,
        chatId: message.chatId,
        text: Degradation.providerUnavailable
      )
    case .budgetDenied(let cap):
      // The day-spend gate refused before the call issued; nothing armed, plain-language stop.
      return await replies.sendCommandAck(
        updateId: rawUpdate.updateId,
        chatId: message.chatId,
        text: Degradation.budget(cap: cap)
      )
    case .unparseable:
      return await replies.sendCommandAck(
        updateId: rawUpdate.updateId,
        chatId: message.chatId,
        text: ScheduleReplies.parseFailed
      )
    case .draft(let draft):
      let nowDate = now()
      switch schedule.validator.validate(draft, now: nowDate) {
      case .failure(let problem):
        return await replies.sendCommandAck(
          updateId: rawUpdate.updateId,
          chatId: message.chatId,
          text: problem.ownerReply
        )
      case .success(let validated):
        // Single slot per session: a second /schedule visibly displaces the older draft.
        await pendingConfirmations.park(.command(.scheduleArm(validated)), sessionId: sessionId)
        return await replies.sendCommandAck(
          updateId: rawUpdate.updateId,
          chatId: message.chatId,
          text: ScheduleReplies.confirmPrompt(
            schedule: validated,
            nextFires: schedule.policy.confirmPreview(
              for: validated,
              from: nowDate,
              limit: ScheduleReplies.confirmPreviewCount
            )
          )
        )
      }
    }
  }

  /// `/schedule list`: read-only, deduped via the canned-reply claim like
  /// `CommandHandlers.memoryReview`.
  func list(rawUpdate: RawUpdate, chatId: Int64) async throws(RoutingHalt) -> HandleOutcome {
    let jobs = try await replies.perform(
      "schedule list",
      updateId: rawUpdate.updateId,
      chatId: chatId
    ) {
      try schedule.jobs.listAll()
    }

    guard jobs.isEmpty == false else {
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        chatId: chatId,
        text: ScheduleReplies.emptyList
      )
    }

    let rows = jobs.map { job in
      (job: job, nextFire: displayNextFire(job))
    }
    return await replies.sendCanned(
      updateId: rawUpdate.updateId,
      chatId: chatId,
      text: ScheduleReplies.listLines(rows)
    )
  }

  func pause(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    jobId: Int64?
  ) async throws(RoutingHalt) -> HandleOutcome {
    guard let jobId else {
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        chatId: message.chatId,
        text: ScheduleReplies.pauseUsage
      )
    }
    try await replies.claimUpdate(updateId: rawUpdate.updateId, chatId: message.chatId)

    let paused = try await replies.perform(
      "pause",
      updateId: rawUpdate.updateId,
      chatId: message.chatId,
      onFailure: .ack(ScheduleReplies.verbFailed)
    ) {
      try schedule.jobs.pause(id: jobId, now: now())
    }

    let reply = paused.map(ScheduleReplies.paused) ?? ScheduleReplies.notFound(id: jobId)
    return await replies.sendCommandAck(
      updateId: rawUpdate.updateId,
      chatId: message.chatId,
      text: reply
    )
  }

  func resume(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    jobId: Int64?
  ) async throws(RoutingHalt) -> HandleOutcome {
    guard let jobId else {
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        chatId: message.chatId,
        text: ScheduleReplies.resumeUsage
      )
    }
    try await replies.claimUpdate(updateId: rawUpdate.updateId, chatId: message.chatId)

    // The CALLER recomputes next-from-now: occurrences inside the paused
    // window are skipped, never caught up. No race with the ticker: the row is PAUSED
    // until `resume` commits, and the ticker's scan predicate excludes PAUSED.
    let job = try await replies.perform(
      "resume lookup",
      updateId: rawUpdate.updateId,
      chatId: message.chatId,
      onFailure: .ack(ScheduleReplies.verbFailed)
    ) {
      try schedule.jobs.job(id: jobId)
    }

    guard let job else {
      return await replies.sendCommandAck(
        updateId: rawUpdate.updateId,
        chatId: message.chatId,
        text: ScheduleReplies.notFound(id: jobId)
      )
    }

    let resumed = try await replies.perform(
      "resume",
      updateId: rawUpdate.updateId,
      chatId: message.chatId,
      onFailure: .ack(ScheduleReplies.verbFailed)
    ) {
      try schedule.jobs.resume(
        id: jobId,
        nextOccurrence: schedule.policy.resumeOccurrence(for: job, from: now()),
        now: now()
      )
    }

    let reply = resumed.map(ScheduleReplies.resumed) ?? ScheduleReplies.notFound(id: jobId)
    return await replies.sendCommandAck(
      updateId: rawUpdate.updateId,
      chatId: message.chatId,
      text: reply
    )
  }

  func runNow(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    jobId: Int64?
  ) async throws(RoutingHalt) -> HandleOutcome {
    guard let jobId else {
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        chatId: message.chatId,
        text: ScheduleReplies.runNowUsage
      )
    }
    try await replies.claimUpdate(updateId: rawUpdate.updateId, chatId: message.chatId)

    let fire = try await replies.perform(
      "run-now",
      updateId: rawUpdate.updateId,
      chatId: message.chatId,
      onFailure: .ack(ScheduleReplies.verbFailed)
    ) {
      try schedule.jobs.fireNow(jobId: jobId, now: now())
    }

    guard let fire else {
      return await replies.sendCommandAck(
        updateId: rawUpdate.updateId,
        chatId: message.chatId,
        text: ScheduleReplies.notFound(id: jobId)
      )
    }

    // The fused fireNow already created the session, trigger message, PENDING run, and
    // jobExecuted audit; TurnEnqueuer gives the run ordering and cancellability.
    await enqueuer.enqueue(fire: fire)

    return await replies.sendCommandAck(
      updateId: rawUpdate.updateId,
      chatId: message.chatId,
      text: ScheduleReplies.runningNow(id: jobId)
    )
  }

  func cancelJob(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    jobId: Int64?
  ) async throws(RoutingHalt) -> HandleOutcome {
    guard let jobId else {
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        chatId: message.chatId,
        text: ScheduleReplies.cancelUsage
      )
    }
    try await replies.claimUpdate(updateId: rawUpdate.updateId, chatId: message.chatId)

    let cancelled = try await replies.perform(
      "cancel",
      updateId: rawUpdate.updateId,
      chatId: message.chatId,
      onFailure: .ack(ScheduleReplies.verbFailed)
    ) {
      try schedule.jobs.cancel(id: jobId, now: now())
    }

    let reply = cancelled.map(ScheduleReplies.cancelled) ?? ScheduleReplies.notFound(id: jobId)
    return await replies.sendCommandAck(
      updateId: rawUpdate.updateId,
      chatId: message.chatId,
      text: reply
    )
  }
}

// MARK: - List Rendering

private extension ScheduleHandlers {
  /// The list's next-fire column: the stored `next_occurrence`, which is itself
  /// calculator-produced — materialized at arm time and advanced only inside the claim —
  /// so the list can never disagree with what actually fires,
  /// including everyNMinutes phase. Non-ACTIVE rows show none.
  func displayNextFire(_ job: ScheduledJob) -> Date? {
    if job.status == .active {
      return job.nextOccurrence
    }
    return nil
  }
}
