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
  private let pendingConfirmations: PendingConfirmationRegistry
  private let botUsername: String?
  private let accessControl: AccessControl
  private let transport: any TelegramTransport
  private let turnRunner: any TurnDispatching
  private let lanes: SessionLaneRegistry
  private let schedule: ScheduleSurface
  private let now: @Sendable () -> Date
  private let logger: Logger
  private let replies: ReplySender
  private let enqueuer: TurnEnqueuer
  private let turnDispatch: TurnDispatch
  private let confirmations: ConfirmationResolver
  private let commandHandlers: CommandHandlers

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
    self.pendingConfirmations = pendingConfirmations
    self.botUsername = botUsername
    self.accessControl = accessControl
    self.transport = transport
    self.turnRunner = turnRunner
    self.lanes = lanes
    self.schedule = schedule
    self.now = now
    self.logger = logger
    self.replies = ReplySender(processed: processed, transport: transport, logger: logger)
    self.commandHandlers = CommandHandlers(
      commands: commands,
      sessionMessages: sessionMessages,
      memory: memory,
      pendingConfirmations: pendingConfirmations,
      lanes: lanes,
      replies: self.replies,
      now: now,
      logger: logger
    )
    self.enqueuer = TurnEnqueuer(lanes: lanes, turns: turnRunner, logger: logger)
    let turnDispatch = TurnDispatch(
      sessionMessages: sessionMessages,
      enqueuer: self.enqueuer,
      replies: self.replies,
      now: now,
      logger: logger
    )
    self.turnDispatch = turnDispatch
    self.confirmations = ConfirmationResolver(
      sessionMessages: sessionMessages,
      pendingConfirmations: pendingConfirmations,
      memoryCommands: memoryCommands,
      schedule: schedule,
      turnDispatch: turnDispatch,
      replies: self.replies,
      now: now,
      logger: logger
    )
  }

  static let welcomeText = "Hi! I'm online. Send me a message and I'll do my best to help."
  static let privateBotText = "Sorry, this is a private bot."

  static func unsupportedMediaText(kind: String) -> String {
    "I can't read \(kind) yet."
  }

  @discardableResult
  public func handle(rawUpdate: RawUpdate) async -> HandleOutcome {
    do throws(RoutingHalt) {
      return try await route(rawUpdate: rawUpdate)
    } catch {
      return error.outcome
    }
  }

  private func route(rawUpdate: RawUpdate) async throws(RoutingHalt) -> HandleOutcome {
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
        return await replies.sendCanned(
          updateId: rawUpdate.updateId,
          chatId: message.chatId,
          text: reply
        )
      case .stop:
        guard isAllowed else {
          return await replies.sendPrivateBot(updateId: rawUpdate.updateId, chatId: message.chatId)
        }
        return try await commandHandlers.stop(rawUpdate: rawUpdate, message: message)
      case .new:
        guard isAllowed else {
          return await replies.sendPrivateBot(updateId: rawUpdate.updateId, chatId: message.chatId)
        }
        return try await commandHandlers.new(rawUpdate: rawUpdate, message: message)
      case .remember(let rememberCommand):
        guard isAllowed else {
          return await replies.sendPrivateBot(updateId: rawUpdate.updateId, chatId: message.chatId)
        }
        return try await commandHandlers.remember(
          rawUpdate: rawUpdate,
          message: message,
          command: rememberCommand
        )
      case .memory(let memoryCommand):
        guard isAllowed else {
          return await replies.sendPrivateBot(updateId: rawUpdate.updateId, chatId: message.chatId)
        }
        return try await commandHandlers.memory(
          rawUpdate: rawUpdate,
          message: message,
          command: memoryCommand
        )
      case .schedule, .pause, .resume, .runNow, .cancelJob, .help:
        guard isAllowed else {
          return await replies.sendPrivateBot(updateId: rawUpdate.updateId, chatId: message.chatId)
        }
        return await handleScheduleCommand(command, rawUpdate: rawUpdate, message: message)
      case .plain(let plainText):
        guard isAllowed else {
          return await replies.sendPrivateBot(updateId: rawUpdate.updateId, chatId: message.chatId)
        }
        if let resolved = try await confirmations.resolve(
          rawUpdate: rawUpdate,
          message: message,
          text: plainText
        ) {
          return resolved
        }
        return try await turnDispatch.dispatch(
          rawUpdate: rawUpdate,
          message: message,
          text: plainText
        )
      }
    case .unsupported(let kind):
      // Never reveal capabilities to a stranger; the owner gets a specific "can't read X yet".
      let reply = isAllowed ? Self.unsupportedMediaText(kind: kind) : Self.privateBotText
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        chatId: message.chatId,
        text: reply
      )
    }
  }

  private static func unauthorizedStartText(userId: Int64) -> String {
    """
    This is a private bot. Your Telegram user ID is \(userId). Ask the owner to add it to the allowlist.
    """
  }
}

// MARK: - Schedule Creation & Listing

private extension MessageRouter {
  /// Fans the allowlisted scheduling family — plus `/help`, which shares the identical
  /// owner-only `isAllowed` gate and has no state of its own to warrant a standalone arm in
  /// `handle` — out to its per-verb handler. The `isAllowed` gate is applied once by the caller
  /// for the whole family; `default` is unreachable — only the schedule create/list command,
  /// the four management verbs, and `/help` route here.
  func handleScheduleCommand(
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
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
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
  func handleScheduleCreate(
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
        await pendingConfirmations.park(.command(.scheduleArm(validated)), sessionId: sessionId)
        return await sendCommandAck(
          rawUpdate: rawUpdate,
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

  /// `/schedule list` (spec §9): read-only, deduped via the canned-reply claim like
  /// `CommandHandlers.memoryReview`.
  func handleScheduleList(rawUpdate: RawUpdate, chatId: Int64) async -> HandleOutcome {
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
  func displayNextFire(_ job: ScheduledJob) -> Date? {
    guard job.status == .active else {
      return nil
    }
    return job.nextOccurrence
  }

  // MARK: - Schedule Management Verbs

  /// Claims a verb command's update BEFORE its effect, so a redelivered command applies once
  /// (spec §5.4: /runnow idempotency rides the update_id claim; pause/resume/cancel get the
  /// same discipline for uniformity). nil ⇒ claimed, proceed; non-nil ⇒ the outcome to return.
  func claimVerbUpdate(rawUpdate: RawUpdate, chatId: Int64) async -> HandleOutcome? {
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

  func handlePause(
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

  func handleResume(
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
        nextOccurrence: schedule.policy.resumeOccurrence(for: job, from: now()),
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

  func handleRunNow(
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

    // The fused fireNow already created the session, trigger message, PENDING run, and
    // jobExecuted audit; TurnEnqueuer gives the run ordering and cancellability (D1).
    await enqueuer.enqueue(fire: fire)

    return await sendCommandAck(
      rawUpdate: rawUpdate,
      chatId: message.chatId,
      text: ScheduleReplies.runningNow(id: jobId)
    )
  }

  func handleCancelJob(
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

  // MARK: - Outbound Replies

  func sendCommandAck(rawUpdate: RawUpdate, chatId: Int64, text: String) async -> HandleOutcome {
    await replies.sendCommandAck(updateId: rawUpdate.updateId, chatId: chatId, text: text)
  }

  func sendCanned(rawUpdate: RawUpdate, chatId: Int64, text: String) async -> HandleOutcome {
    await replies.sendCanned(updateId: rawUpdate.updateId, chatId: chatId, text: text)
  }

  func storageFull(chatId: Int64) async -> HandleOutcome {
    await replies.storageFull(chatId: chatId)
  }
}
