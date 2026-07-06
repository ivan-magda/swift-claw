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
  private let schedule: ScheduleSurface
  private let now: @Sendable () -> Date
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
    schedule: ScheduleSurface,
    now: @escaping @Sendable () -> Date = { Date() },
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
    self.schedule = schedule
    self.now = now
    self.logger = logger
  }

  static let welcomeText = "Hi! I'm online. Send me a message and I'll do my best to help."
  static let privateBotText = "Sorry, this is a private bot."

  static func unsupportedMediaText(kind: String) -> String {
    "I can't read \(kind) yet."
  }

  @discardableResult
  public func handle(rawUpdate: RawUpdate) async -> HandleOutcome {
    guard let message = IncomingMessage.normalize(from: rawUpdate) else {
      logger.debug("update \(rawUpdate.updateId) has nothing actionable, skipping")
      return .skipped
    }

    let isAllowed = accessControl.isAllowed(userId: message.userId)

    switch message.content {
    case .text(let text):
      let command = Command.parse(text, botUsername: botUsername)
      switch command {
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
      case .schedule, .pause, .resume, .runNow, .cancelJob, .help:
        guard isAllowed else {
          return await sendPrivateBotReply(rawUpdate: rawUpdate, chatId: message.chatId)
        }
        return await handleScheduleCommand(command, rawUpdate: rawUpdate, message: message)
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
      let reply = isAllowed ? Self.unsupportedMediaText(kind: kind) : Self.privateBotText
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
      await pendingConfirmations.clear(sessionId: sessionId)
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

  /// Fans the allowlisted scheduling family — plus `/help`, which shares the identical
  /// owner-only `isAllowed` gate and has no state of its own to warrant a standalone arm in
  /// `handle` — out to its per-verb handler. The `isAllowed` gate is applied once by the caller
  /// for the whole family; `default` is unreachable — only the schedule create/list command,
  /// the four management verbs, and `/help` route here.
  private func handleScheduleCommand(
    _ command: Command,
    rawUpdate: RawUpdate,
    message: IncomingMessage
  ) async -> HandleOutcome {
    switch command {
    case .schedule(.create(let text)):
      return await handleScheduleCreate(rawUpdate: rawUpdate, message: message, text: text)
    case .schedule(.list):
      return await handleScheduleList(rawUpdate: rawUpdate, chatId: message.chatId)
    case .pause(let jobId):
      return await handlePause(rawUpdate: rawUpdate, message: message, jobId: jobId)
    case .resume(let jobId):
      return await handleResume(rawUpdate: rawUpdate, message: message, jobId: jobId)
    case .runNow(let jobId):
      return await handleRunNow(rawUpdate: rawUpdate, message: message, jobId: jobId)
    case .cancelJob(let jobId):
      return await handleCancelJob(rawUpdate: rawUpdate, message: message, jobId: jobId)
    case .help:
      return await sendCanned(
        rawUpdate: rawUpdate,
        chatId: message.chatId,
        text: CommandReplies.help
      )
    default:
      logger.error("non-schedule command \(command) reached handleScheduleCommand")
      return .skipped
    }
  }

  /// `/schedule <text>` (spec §7/§8): claim the update, run the ONE parse call, validate
  /// deterministically, park the validated draft, and send the gateway-authored confirm prompt.
  /// Nothing is armed here; every failure is a plain-language reply and parks nothing.
  private func handleScheduleCreate(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    text: String
  ) async -> HandleOutcome {
    let claim: CommandClaim
    do {
      claim = try sessionMessages.claimCommandUpdate(
        updateId: rawUpdate.updateId,
        sessionKey: SessionKey.telegramDM(chatId: message.chatId),
        now: now()
      )
    } catch StoreError.diskFull {
      return await storageFull(chatId: message.chatId)
    } catch {
      logger.error("schedule claim failed for update \(rawUpdate.updateId): \(error)")
      return .transientFailure
    }

    guard case .claimed(let sessionId) = claim else {
      logger.debug("duplicate update \(rawUpdate.updateId), skipping")
      return .skipped
    }

    switch await schedule.parser.parse(ownerText: text) {
    case .providerUnavailable:
      // DEG-01: an LLM/API failure degrades exactly like any turn; nothing armed.
      return await sendCommandAck(
        rawUpdate: rawUpdate,
        chatId: message.chatId,
        text: Degradation.providerUnavailable
      )
    case .unparseable:
      return await sendCommandAck(
        rawUpdate: rawUpdate,
        chatId: message.chatId,
        text: ScheduleReplies.parseFailed
      )
    case .draft(let draft):
      let nowDate = now()
      switch schedule.validator.validate(draft, now: nowDate) {
      case .failure(let problem):
        return await sendCommandAck(
          rawUpdate: rawUpdate,
          chatId: message.chatId,
          text: problem.ownerReply
        )
      case .success(let validated):
        // Single slot per session: a second /schedule visibly displaces the older draft (§9).
        await pendingConfirmations.park(.scheduleArm(validated), sessionId: sessionId)
        return await sendCommandAck(
          rawUpdate: rawUpdate,
          chatId: message.chatId,
          text: ScheduleReplies.confirmPrompt(
            schedule: validated,
            nextFires: nextFires(for: validated, from: nowDate)
          )
        )
      }
    }
  }

  /// The confirm preview's fire times. The SAME `nowDate` that validation used seeds the
  /// calculator, so the preview's first entry IS the parked `firstOccurrence`.
  private func nextFires(for validated: ValidatedSchedule, from nowDate: Date) -> [Date] {
    guard
      let envelope = validated.recurrence,
      let timezone = TimeZone(identifier: validated.timezone)
    else {
      return [validated.firstOccurrence]
    }
    return schedule.calculator.occurrences(
      rule: envelope.rule,
      timezone: timezone,
      anchor: nowDate,
      after: nowDate,
      limit: ScheduleReplies.confirmPreviewCount
    )
  }

  /// The fire time to arm with. Anchoring on the parked `firstOccurrence` (not arm-time `now`)
  /// keeps the previewed everyNMinutes phase intact (preamble deviation #1: phase-continuous from
  /// preview through every fire) — mirroring `resumeNextOccurrence`, which anchors on the stored
  /// occurrence rather than `now` for the same reason. `after: nowDate` still does the M1 job: it
  /// skips any occurrence already past by confirm time, so a draft confirmed long after its
  /// preview can't arm an already-past occurrence (a one-shot would silently misfire to COMPLETED;
  /// a recurring one would fire immediately). This re-runs the SAME parked rule — not a re-parse
  /// (§8): label/prompt/rule/timezone are still the parked draft's. Returns nil when nothing valid
  /// remains to arm: a one-shot whose instant has passed, or (pathological) a rule with no
  /// upcoming occurrence.
  private func armNextOccurrence(for validated: ValidatedSchedule, now nowDate: Date) -> Date? {
    guard let envelope = validated.recurrence else {
      return validated.firstOccurrence > nowDate ? validated.firstOccurrence : nil
    }
    guard let timezone = TimeZone(identifier: validated.timezone) else {
      return validated.firstOccurrence > nowDate ? validated.firstOccurrence : nil
    }
    return schedule.calculator.occurrences(
      rule: envelope.rule,
      timezone: timezone,
      anchor: validated.firstOccurrence,
      after: nowDate,
      limit: 1
    ).first
  }

  /// `/schedule list` (spec §9): read-only, deduped via the canned-reply claim like
  /// `handleMemoryReview`.
  private func handleScheduleList(rawUpdate: RawUpdate, chatId: Int64) async -> HandleOutcome {
    let jobs: [ScheduledJob]
    do {
      jobs = try schedule.jobs.listAll()
    } catch StoreError.diskFull {
      return await storageFull(chatId: chatId)
    } catch {
      logger.error("schedule list failed for update \(rawUpdate.updateId): \(error)")
      return .transientFailure
    }

    guard jobs.isEmpty == false else {
      return await sendCanned(rawUpdate: rawUpdate, chatId: chatId, text: ScheduleReplies.emptyList)
    }

    let rows = jobs.map { job in
      (job: job, nextFire: displayNextFire(job))
    }
    return await sendCanned(
      rawUpdate: rawUpdate,
      chatId: chatId,
      text: ScheduleReplies.listLines(rows)
    )
  }

  /// The list's next-fire column: the stored `next_occurrence`, which is itself
  /// calculator-produced — materialized at arm time and advanced only inside the claim (§4.1) —
  /// so the list can never disagree with what actually fires (spec §9's single-source rule),
  /// including everyNMinutes phase. Non-ACTIVE rows show none.
  private func displayNextFire(_ job: ScheduledJob) -> Date? {
    guard job.status == .active else {
      return nil
    }
    return job.nextOccurrence
  }

  /// Claims a verb command's update BEFORE its effect, so a redelivered command applies once
  /// (spec §5.4: /runnow idempotency rides the update_id claim; pause/resume/cancel get the
  /// same discipline for uniformity). nil ⇒ claimed, proceed; non-nil ⇒ the outcome to return.
  private func claimVerbUpdate(rawUpdate: RawUpdate, chatId: Int64) async -> HandleOutcome? {
    do {
      guard try processed.claimUpdate(updateId: rawUpdate.updateId) else {
        logger.debug("duplicate update \(rawUpdate.updateId), skipping")
        return .skipped
      }
    } catch StoreError.diskFull {
      return await storageFull(chatId: chatId)
    } catch {
      logger.error("verb claim failed for update \(rawUpdate.updateId): \(error)")
      return .transientFailure
    }
    return nil
  }

  private func handlePause(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    jobId: Int64?
  ) async -> HandleOutcome {
    guard let jobId else {
      return await sendCanned(
        rawUpdate: rawUpdate,
        chatId: message.chatId,
        text: ScheduleReplies.pauseUsage
      )
    }
    if let handled = await claimVerbUpdate(rawUpdate: rawUpdate, chatId: message.chatId) {
      return handled
    }

    let paused: ScheduledJob?
    do {
      paused = try schedule.jobs.pause(id: jobId, now: now())
    } catch StoreError.diskFull {
      return await storageFull(chatId: message.chatId)
    } catch {
      logger.error("pause failed for update \(rawUpdate.updateId): \(error)")
      return await sendCommandAck(
        rawUpdate: rawUpdate,
        chatId: message.chatId,
        text: ScheduleReplies.verbFailed
      )
    }

    let reply = paused.map(ScheduleReplies.paused) ?? ScheduleReplies.notFound(id: jobId)
    return await sendCommandAck(rawUpdate: rawUpdate, chatId: message.chatId, text: reply)
  }

  private func handleResume(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    jobId: Int64?
  ) async -> HandleOutcome {
    guard let jobId else {
      return await sendCanned(
        rawUpdate: rawUpdate,
        chatId: message.chatId,
        text: ScheduleReplies.resumeUsage
      )
    }
    if let handled = await claimVerbUpdate(rawUpdate: rawUpdate, chatId: message.chatId) {
      return handled
    }

    let resumed: ScheduledJob?
    do {
      // The CALLER recomputes next-from-now (preamble contract): occurrences inside the paused
      // window are skipped, never caught up (§5.4). No race with the ticker: the row is PAUSED
      // until `resume` commits, and the ticker's scan predicate excludes PAUSED.
      guard let job = try schedule.jobs.job(id: jobId) else {
        return await sendCommandAck(
          rawUpdate: rawUpdate,
          chatId: message.chatId,
          text: ScheduleReplies.notFound(id: jobId)
        )
      }
      resumed = try schedule.jobs.resume(
        id: jobId,
        nextOccurrence: resumeNextOccurrence(job: job, from: now()),
        now: now()
      )
    } catch StoreError.diskFull {
      return await storageFull(chatId: message.chatId)
    } catch {
      logger.error("resume failed for update \(rawUpdate.updateId): \(error)")
      return await sendCommandAck(
        rawUpdate: rawUpdate,
        chatId: message.chatId,
        text: ScheduleReplies.verbFailed
      )
    }

    let reply = resumed.map(ScheduleReplies.resumed) ?? ScheduleReplies.notFound(id: jobId)
    return await sendCommandAck(rawUpdate: rawUpdate, chatId: message.chatId, text: reply)
  }

  /// Resume's next fire: recurring ⇒ the calculator's next occurrence after now (anchored at
  /// the job's createdTs like every other occurrence read); one-shot ⇒ its stored instant if
  /// still ahead, else nothing left to fire.
  private func resumeNextOccurrence(job: ScheduledJob, from nowDate: Date) -> Date? {
    guard
      let envelope = job.recurrence,
      let timezone = TimeZone(identifier: job.timezone)
    else {
      guard let instant = job.nextOccurrence, instant > nowDate else {
        return nil
      }
      return instant
    }
    // Anchor = the stale stored next (pause leaves next_occurrence untouched): the recompute
    // stays on the armed chain — everyNMinutes keeps its phase — while `after: nowDate` skips
    // everything inside the paused window (§5.4: pause = "be quiet", never catch up).
    return schedule.calculator.occurrences(
      rule: envelope.rule,
      timezone: timezone,
      anchor: job.nextOccurrence ?? job.createdTs,
      after: nowDate,
      limit: 1
    ).first
  }

  private func handleRunNow(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    jobId: Int64?
  ) async -> HandleOutcome {
    guard let jobId else {
      return await sendCanned(
        rawUpdate: rawUpdate,
        chatId: message.chatId,
        text: ScheduleReplies.runNowUsage
      )
    }
    if let handled = await claimVerbUpdate(rawUpdate: rawUpdate, chatId: message.chatId) {
      return handled
    }

    let fire: ClaimedFire?
    do {
      fire = try schedule.jobs.fireNow(jobId: jobId, now: now())
    } catch StoreError.diskFull {
      return await storageFull(chatId: message.chatId)
    } catch {
      logger.error("run-now failed for update \(rawUpdate.updateId): \(error)")
      return await sendCommandAck(
        rawUpdate: rawUpdate,
        chatId: message.chatId,
        text: ScheduleReplies.verbFailed
      )
    }

    guard let fire else {
      return await sendCommandAck(
        rawUpdate: rawUpdate,
        chatId: message.chatId,
        text: ScheduleReplies.notFound(id: jobId)
      )
    }

    // Exactly the SchedulerService post-claim enqueue: the fused fireNow already created the
    // session, trigger message, PENDING run, and jobExecuted audit; the lane gives the run
    // ordering and cancellability, and `run` may throw only StoreError.diskFull (D1).
    let lane = await lanes.actor(for: fire.sessionId)
    await lane.enqueue(runId: fire.runId) { [turnRunner, logger] in
      do {
        try await turnRunner.run(
          runId: fire.runId,
          sessionId: fire.sessionId,
          chatId: fire.ownerChatId,
          triggerMessageId: fire.triggerMessageId,
          grant: nil
        )
      } catch StoreError.diskFull {
        logger.error("run-now turn \(fire.runId) stopped by storage full after enqueue")
      } catch {
        logger.error("run-now turn error (handled in-band) for job \(jobId): \(error)")
      }
    }

    return await sendCommandAck(
      rawUpdate: rawUpdate,
      chatId: message.chatId,
      text: ScheduleReplies.runningNow(id: jobId)
    )
  }

  private func handleCancelJob(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    jobId: Int64?
  ) async -> HandleOutcome {
    guard let jobId else {
      return await sendCanned(
        rawUpdate: rawUpdate,
        chatId: message.chatId,
        text: ScheduleReplies.cancelUsage
      )
    }
    if let handled = await claimVerbUpdate(rawUpdate: rawUpdate, chatId: message.chatId) {
      return handled
    }

    let cancelled: ScheduledJob?
    do {
      cancelled = try schedule.jobs.cancel(id: jobId, now: now())
    } catch StoreError.diskFull {
      return await storageFull(chatId: message.chatId)
    } catch {
      logger.error("cancel failed for update \(rawUpdate.updateId): \(error)")
      return await sendCommandAck(
        rawUpdate: rawUpdate,
        chatId: message.chatId,
        text: ScheduleReplies.verbFailed
      )
    }

    let reply = cancelled.map(ScheduleReplies.cancelled) ?? ScheduleReplies.notFound(id: jobId)
    return await sendCommandAck(rawUpdate: rawUpdate, chatId: message.chatId, text: reply)
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

    // A tool approval differs from the memory-confirm flow: BOTH a confirm and a non-confirm
    // reply become an ordinary persisted turn (never a command ack, §14), so it resolves here,
    // before the memory-only commit/cancel switch below ever sees the entry.
    if case .toolApproval(let request) = entry {
      await pendingConfirmations.clear(sessionId: sessionId)
      let grant: OneTurnGrant? =
        ConfirmationReply.parse(text) == .confirm
        ? OneTurnGrant(action: request.action)
        : nil
      return await dispatchTurn(
        rawUpdate: rawUpdate,
        message: message,
        text: text,
        grant: grant
      )
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

  /// Confirms a parked effect through its atomic claim+effect+audit store seam.
  private func commitPending(
    _ entry: PendingConfirmation,
    sessionId: Int64,
    rawUpdate: RawUpdate,
    message: IncomingMessage
  ) async -> HandleOutcome {
    // A parked schedule can be confirmed long after its preview; recompute the fire time from the
    // parked rule against the arm-time clock (details in armNextOccurrence). A one-shot whose
    // instant has passed cannot be salvaged — reject it so the owner reschedules rather than
    // arming a job that silently never fires.
    var scheduleArmNext: Date?
    if case .scheduleArm(let validated) = entry {
      guard let recomputed = armNextOccurrence(for: validated, now: now()) else {
        return await rejectStaleArm(sessionId: sessionId, rawUpdate: rawUpdate, message: message)
      }
      scheduleArmNext = recomputed
    }

    let newlyClaimed: Bool
    let ackText: String
    do {
      switch entry {
      case .rememberWrite(let request):
        let result = try memoryCommands.applyRemember(
          updateId: rawUpdate.updateId,
          item: request.item,
          now: Date()
        )
        newlyClaimed = result.newlyClaimed
        ackText = MemoryReplies.saved(id: result.item?.id)
      case .deleteItem(let itemId):
        let result = try memoryCommands.applyForget(
          updateId: rawUpdate.updateId,
          itemId: itemId,
          now: Date()
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
      case .toolApproval:
        preconditionFailure("approvals resolve in resolvePendingConfirmation before commitPending")
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

    guard newlyClaimed else {
      logger.debug("duplicate update \(rawUpdate.updateId), skipping")
      return .skipped
    }

    await pendingConfirmations.clear(sessionId: sessionId)

    return await sendCommandAck(rawUpdate: rawUpdate, chatId: message.chatId, text: ackText)
  }

  /// A parked schedule confirmed after its only fire time has passed: nothing valid remains to
  /// arm. Claim the update (dedup), clear the slot, and tell the owner to reschedule.
  private func rejectStaleArm(
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
      logger.error("stale-arm claim failed for update \(rawUpdate.updateId): \(error)")
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
      text: ScheduleReplies.armExpired
    )
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
    case .scheduleArm:
      errorText = ScheduleReplies.armFailed
    case .toolApproval:
      preconditionFailure("approvals resolve in resolvePendingConfirmation before commitPending")
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
    text: String,
    grant: OneTurnGrant? = nil
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

    // The inbound → run bridge: the one INFO line that shows a real message was accepted and which
    // run it became. run/session/update ride as metadata so the whole lifecycle greps by `run=<id>`;
    // only the message SIZE is logged, never its text.
    var runLog = logger
    runLog[metadataKey: "run"] = "\(runId)"
    runLog[metadataKey: "session"] = "\(sessionId)"
    runLog[metadataKey: "update"] = "\(rawUpdate.updateId)"
    runLog.info(
      "message accepted; dispatching run (chars=\(text.count) edited=\(message.isEdited))"
    )

    let lane = await lanes.actor(for: sessionId)
    await lane.enqueue(runId: runId) { [turnRunner, runLog] in
      do {
        try await turnRunner.run(
          runId: runId,
          sessionId: sessionId,
          chatId: message.chatId,
          triggerMessageId: triggerMessageId,
          grant: grant
        )
      } catch StoreError.diskFull {
        runLog.error("turn stopped by storage full after enqueue")
      } catch {
        runLog.error("turn run error (handled in-band): \(error)")
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
