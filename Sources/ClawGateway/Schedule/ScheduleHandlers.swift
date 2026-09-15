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
      updateID: rawUpdate.updateID,
      target: .chat(message.chatID)
    ) {
      try sessionMessages.claimCommandUpdate(
        updateID: rawUpdate.updateID,
        sessionKey: SessionKey.telegramDM(chatID: message.chatID),
        now: now()
      )
    }

    guard case .claimed(let sessionID) = claim else {
      return replies.skipDuplicate(updateID: rawUpdate.updateID)
    }

    let parseResult = await schedule.parser.parse(ownerText: text, sessionID: sessionID)
    switch parseResult {
    case .providerUnavailable, .authenticationRequired, .accessDenied, .quotaLimited:
      // Every provider-side failure gives the same actionable guidance a turn does and arms nothing:
      // the auth reply names `clawd auth login`; access and quota deliberately do NOT say to log in.
      return await replies.sendCommandAck(
        updateID: rawUpdate.updateID,
        target: .chat(message.chatID),
        text: ScheduleReplies.providerFailure(parseResult)
      )
    case .budgetDenied(let cap):
      // The day-spend gate refused before the call issued; nothing armed, plain-language stop.
      return await replies.sendCommandAck(
        updateID: rawUpdate.updateID,
        target: .chat(message.chatID),
        text: Degradation.budget(cap: cap)
      )
    case .unparseable:
      return await replies.sendCommandAck(
        updateID: rawUpdate.updateID,
        target: .chat(message.chatID),
        text: ScheduleReplies.parseFailed
      )
    case .draft(let draft):
      let nowDate = now()
      switch schedule.validator.validate(draft, now: nowDate) {
      case .failure(let problem):
        return await replies.sendCommandAck(
          updateID: rawUpdate.updateID,
          target: .chat(message.chatID),
          text: problem.ownerReply
        )
      case .success(let validated):
        // Single slot per session: a second /schedule visibly displaces the older draft.
        await pendingConfirmations.park(.scheduleArm(validated), sessionID: sessionID)
        return await replies.sendCommandAck(
          updateID: rawUpdate.updateID,
          target: .chat(message.chatID),
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
  func list(rawUpdate: RawUpdate, chatID: Int64) async throws(RoutingHalt) -> HandleOutcome {
    let jobs = try await replies.perform(
      "schedule list",
      updateID: rawUpdate.updateID,
      target: .chat(chatID)
    ) {
      try schedule.jobs.listAll()
    }

    guard jobs.isEmpty == false else {
      return await replies.sendCanned(
        updateID: rawUpdate.updateID,
        target: .chat(chatID),
        text: ScheduleReplies.emptyList
      )
    }

    let rows = jobs.map { job in
      (job: job, nextFire: displayNextFire(job))
    }
    return await replies.sendCanned(
      updateID: rawUpdate.updateID,
      target: .chat(chatID),
      text: ScheduleReplies.listLines(rows)
    )
  }

  func pause(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    jobID: Int64?
  ) async throws(RoutingHalt) -> HandleOutcome {
    guard let jobID else {
      return await replies.sendCanned(
        updateID: rawUpdate.updateID,
        target: .chat(message.chatID),
        text: ScheduleReplies.pauseUsage
      )
    }
    try await replies.claimUpdate(updateID: rawUpdate.updateID, target: .chat(message.chatID))

    let paused = try await replies.perform(
      "pause",
      updateID: rawUpdate.updateID,
      target: .chat(message.chatID),
      onFailure: .ack(ScheduleReplies.verbFailed)
    ) {
      try schedule.jobs.pause(id: jobID, now: now())
    }

    let reply = paused.map(ScheduleReplies.paused) ?? ScheduleReplies.notFound(id: jobID)
    return await replies.sendCommandAck(
      updateID: rawUpdate.updateID,
      target: .chat(message.chatID),
      text: reply
    )
  }

  func resume(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    jobID: Int64?
  ) async throws(RoutingHalt) -> HandleOutcome {
    guard let jobID else {
      return await replies.sendCanned(
        updateID: rawUpdate.updateID,
        target: .chat(message.chatID),
        text: ScheduleReplies.resumeUsage
      )
    }
    try await replies.claimUpdate(updateID: rawUpdate.updateID, target: .chat(message.chatID))

    // The CALLER recomputes next-from-now: occurrences inside the paused
    // window are skipped, never caught up. No race with the ticker: the row is PAUSED
    // until `resume` commits, and the ticker's scan predicate excludes PAUSED.
    let job = try await replies.perform(
      "resume lookup",
      updateID: rawUpdate.updateID,
      target: .chat(message.chatID),
      onFailure: .ack(ScheduleReplies.verbFailed)
    ) {
      try schedule.jobs.job(id: jobID)
    }

    guard let job else {
      return await replies.sendCommandAck(
        updateID: rawUpdate.updateID,
        target: .chat(message.chatID),
        text: ScheduleReplies.notFound(id: jobID)
      )
    }

    let resumed = try await replies.perform(
      "resume",
      updateID: rawUpdate.updateID,
      target: .chat(message.chatID),
      onFailure: .ack(ScheduleReplies.verbFailed)
    ) {
      try schedule.jobs.resume(
        id: jobID,
        nextOccurrence: schedule.policy.resumeOccurrence(for: job, from: now()),
        now: now()
      )
    }

    let reply = resumed.map(ScheduleReplies.resumed) ?? ScheduleReplies.notFound(id: jobID)
    return await replies.sendCommandAck(
      updateID: rawUpdate.updateID,
      target: .chat(message.chatID),
      text: reply
    )
  }

  func runNow(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    jobID: Int64?
  ) async throws(RoutingHalt) -> HandleOutcome {
    guard let jobID else {
      return await replies.sendCanned(
        updateID: rawUpdate.updateID,
        target: .chat(message.chatID),
        text: ScheduleReplies.runNowUsage
      )
    }
    try await replies.claimUpdate(updateID: rawUpdate.updateID, target: .chat(message.chatID))

    let outcome = try await replies.perform(
      "run-now",
      updateID: rawUpdate.updateID,
      target: .chat(message.chatID),
      onFailure: .ack(ScheduleReplies.verbFailed)
    ) {
      try schedule.jobs.fireNow(jobID: jobID, now: now())
    }

    switch outcome {
    case .ineligible:
      return await replies.sendCommandAck(
        updateID: rawUpdate.updateID,
        target: .chat(message.chatID),
        text: ScheduleReplies.notFound(id: jobID)
      )
    case .skippedActiveRun:
      // A real job, but a prior run on its session is still live — the fire was skipped, not
      // failed. Tell the owner rather than claiming the job doesn't exist.
      return await replies.sendCommandAck(
        updateID: rawUpdate.updateID,
        target: .chat(message.chatID),
        text: ScheduleReplies.alreadyRunning(id: jobID)
      )
    case .fired(let fire):
      // The fused fireNow already created the session, trigger message, PENDING run, and
      // jobExecuted audit; TurnEnqueuer gives the run ordering and cancellability.
      await enqueuer.enqueue(fire: fire)
      return await replies.sendCommandAck(
        updateID: rawUpdate.updateID,
        target: .chat(message.chatID),
        text: ScheduleReplies.runningNow(id: jobID)
      )
    }
  }

  func cancelJob(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    jobID: Int64?
  ) async throws(RoutingHalt) -> HandleOutcome {
    guard let jobID else {
      return await replies.sendCanned(
        updateID: rawUpdate.updateID,
        target: .chat(message.chatID),
        text: ScheduleReplies.cancelUsage
      )
    }
    try await replies.claimUpdate(updateID: rawUpdate.updateID, target: .chat(message.chatID))

    let cancelled = try await replies.perform(
      "cancel",
      updateID: rawUpdate.updateID,
      target: .chat(message.chatID),
      onFailure: .ack(ScheduleReplies.verbFailed)
    ) {
      try schedule.jobs.cancel(id: jobID, now: now())
    }

    let reply = cancelled.map(ScheduleReplies.cancelled) ?? ScheduleReplies.notFound(id: jobID)
    return await replies.sendCommandAck(
      updateID: rawUpdate.updateID,
      target: .chat(message.chatID),
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
