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

/// Routes one inbound update: normalize, apply default-deny access control, parse the command,
/// and delegate to the family handler — `CommandHandlers` (/stop, /new, /remember, /memory),
/// `ScheduleHandlers` (the /schedule family), `ConfirmationResolver` (parked yes/no interception,
/// which runs before any turn is dispatched), or `TurnDispatch` (plain text → durable run).
/// The dedup paths share the `processed_updates` key space and each update takes exactly one
/// path, so an update is claimed once. Handlers unwind mapped failures via `RoutingHalt`;
/// `handle` is the single place the outcome returns to the poller.
public struct MessageRouter: Sendable {
  private let botUsername: String?

  private let accessControl: AccessControl
  private let replies: ReplySender

  private let commandHandlers: CommandHandlers
  private let scheduleHandlers: ScheduleHandlers
  private let confirmations: ConfirmationResolver
  private let turnDispatch: TurnDispatch
  private let approvalCallbacks: ApprovalCallbackHandler?
  private let voice: (any VoiceMessageTranscribing)?
  private let images: (any ImageMessageHandling)?
  private let typing: (any TypingIndicator)?

  private let doctor: any DoctorReporting
  private let logger: Logger

  package init(
    processed: any ProcessedUpdateStore,
    sessionMessages: any SessionMessageStore,
    commands: any CommandStore,
    memory: any MemoryStore,
    memoryCommands: any MemoryCommandStore,
    pendingConfirmations: PendingConfirmationRegistry,
    botUsername: String?,
    accessControl: AccessControl,
    delivery: any MessageDelivery,
    turnRunner: any TurnDispatching,
    imageCache: ImageCache,
    lanes: SessionLaneRegistry,
    schedule: ScheduleSurface,
    approvalCallbacks: ApprovalCallbackHandler? = nil,
    voice: (any VoiceMessageTranscribing)? = nil,
    images: (any ImageMessageHandling)? = nil,
    typing: (any TypingIndicator)? = nil,
    coordinator: ApprovalCoordinator,
    doctor: any DoctorReporting,
    now: @escaping @Sendable () -> Date = { Date() },
    logger: Logger
  ) {
    self.botUsername = botUsername

    self.accessControl = accessControl
    self.approvalCallbacks = approvalCallbacks
    self.voice = voice
    self.images = images
    self.typing = typing

    self.doctor = doctor
    self.logger = logger

    let replies = ReplySender(processed: processed, delivery: delivery, logger: logger)
    let enqueuer = TurnEnqueuer(lanes: lanes, turns: turnRunner, logger: logger)
    let turnDispatch = TurnDispatch(
      sessionMessages: sessionMessages,
      enqueuer: enqueuer,
      replies: replies,
      imageCache: imageCache,
      now: now,
      logger: logger
    )

    self.replies = replies
    self.turnDispatch = turnDispatch
    self.commandHandlers = CommandHandlers(
      commands: commands,
      sessionMessages: sessionMessages,
      memory: memory,
      pendingConfirmations: pendingConfirmations,
      lanes: lanes,
      replies: replies,
      now: now,
      logger: logger,
      coordinator: coordinator
    )
    self.scheduleHandlers = ScheduleHandlers(
      schedule: schedule,
      sessionMessages: sessionMessages,
      pendingConfirmations: pendingConfirmations,
      replies: replies,
      enqueuer: enqueuer,
      now: now,
      logger: logger
    )
    self.confirmations = ConfirmationResolver(
      sessionMessages: sessionMessages,
      pendingConfirmations: pendingConfirmations,
      memoryCommands: memoryCommands,
      schedule: schedule,
      replies: replies,
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
}

// MARK: - Routing

private extension MessageRouter {
  func route(rawUpdate: RawUpdate) async throws(RoutingHalt) -> HandleOutcome {
    // A callback-only update normalizes to nil (no message/edited_message); without this branch it
    // would .skipped and the cursor would advance past it. The handler returns a real
    // HandleOutcome, so cursor semantics are unchanged.
    if let callback = rawUpdate.callback {
      guard let approvalCallbacks else {
        logger.debug("callback update \(rawUpdate.updateId) with no approval handler, skipping")
        return .skipped
      }
      return await approvalCallbacks.handle(callback, updateId: rawUpdate.updateId)
    }

    guard let message = IncomingMessage.normalize(from: rawUpdate) else {
      logger.debug("update \(rawUpdate.updateId) has nothing actionable, skipping")
      return .skipped
    }

    let isAllowed = accessControl.isAllowed(userId: message.userId)

    switch message.content {
    case .unsupported(let kind):
      // Never reveal capabilities to a stranger; the owner gets a specific "can't read X yet".
      let reply = isAllowed ? Self.unsupportedMediaText(kind: kind) : Self.privateBotText
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        chatId: message.chatId,
        text: reply
      )
    case .photo(let attachment, let caption):
      return try await routeImage(
        attachment,
        caption: caption,
        rawUpdate: rawUpdate,
        message: message,
        isAllowed: isAllowed
      )
    case .voice(let attachment):
      return try await routeVoice(
        attachment,
        rawUpdate: rawUpdate,
        message: message,
        isAllowed: isAllowed
      )
    case .text(let text):
      let command = Command.parse(text, botUsername: botUsername)
      if isAllowed {
        return try await routeAllowed(command, rawUpdate: rawUpdate, message: message)
      }
      return await denyAccess(command, rawUpdate: rawUpdate, message: message)
    }
  }

  func routeVoice(
    _ attachment: VoiceAttachment,
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    isAllowed: Bool
  ) async throws(RoutingHalt) -> HandleOutcome {
    guard isAllowed else {
      return await replies.sendPrivateBot(updateId: rawUpdate.updateId, chatId: message.chatId)
    }

    guard let voice else {
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        chatId: message.chatId,
        text: Self.unsupportedMediaText(kind: VoiceAttachment.mediaKindDescription)
      )
    }

    switch await voice.transcribe(attachment) {
    case .success(let transcript):
      return try await turnDispatch.dispatch(
        rawUpdate: rawUpdate,
        message: message,
        text: transcript,
        provenance: .untrusted
      )
    case .failure(.storageFull):
      return await replies.storageFull(chatId: message.chatId)
    case .failure(let failure):
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        chatId: message.chatId,
        text: failure.ownerReplyText
      )
    }
  }

  /// Mirrors `routeVoice`: access first, then availability, then the download — all before any
  /// update claim, so a cancellation mid-download leaves the update redeliverable. The caption
  /// dispatches directly and is never command-parsed nor offered to a parked confirmation: a photo
  /// carries no forward metadata, so an owner's own image and a forwarded one are indistinguishable
  /// and neither may steer a control path.
  ///
  /// A caption survives every arm that reaches a turn, including the opted-out one — see
  /// `routeImageWithoutService`. Only a failed download discards it, because there the reply names a
  /// fault the owner can act on rather than silently answering half the message.
  func routeImage(
    _ attachment: PhotoAttachment,
    caption: String?,
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    isAllowed: Bool
  ) async throws(RoutingHalt) -> HandleOutcome {
    guard isAllowed else {
      return await replies.sendPrivateBot(updateId: rawUpdate.updateId, chatId: message.chatId)
    }

    guard let images else {
      return try await routeImageWithoutService(
        caption: caption,
        rawUpdate: rawUpdate,
        message: message
      )
    }

    // After both guards, so neither a stranger nor a disabled service is ever told the bot is
    // awake. Whether the pulse lands is not checked and cannot be: the action auto-expires
    // server-side, so one that never arrives is no reason to fail a photo the owner is waiting on.
    await typing?.sendTyping(chatId: message.chatId)

    switch await images.materialize(attachment) {
    case .success(let image):
      return try await turnDispatch.dispatch(
        rawUpdate: rawUpdate,
        message: message,
        text: ImageMarkers.photoContent(caption: caption),
        provenance: .untrusted,
        image: image
      )
    case .failure(let failure):
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        chatId: message.chatId,
        text: failure.ownerReplyText
      )
    }
  }

  /// The opted-out path, which still owes the owner an answer. A bare photo is only the photo, so
  /// the canned reply is the whole of it. A caption is the owner's own question and must not be
  /// discarded — the product tells them to set this very flag when their model cannot see, so this
  /// is a configuration they are steered into, not an edge case.
  ///
  /// The caption dispatches on the same direct, untrusted path the enabled branch uses. It is
  /// deliberately NOT routed back through command parsing or a parked confirmation: a photo carries
  /// no proof of who composed it, so one captioned `/stop` or `yes` must never steer a control path.
  /// The marker leads the content with no bytes behind it, so assembly renders the "no longer
  /// available" notice and the model is told a photo it cannot see was attached.
  func routeImageWithoutService(
    caption: String?,
    rawUpdate: RawUpdate,
    message: IncomingMessage
  ) async throws(RoutingHalt) -> HandleOutcome {
    guard let caption, caption.isEmpty == false else {
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        chatId: message.chatId,
        text: Self.unsupportedMediaText(kind: PhotoAttachment.mediaKindDescription)
      )
    }

    return try await turnDispatch.dispatch(
      rawUpdate: rawUpdate,
      message: message,
      text: ImageMarkers.photoContent(caption: caption),
      provenance: .untrusted
    )
  }

  /// Default-deny, applied ONCE for every command: a stranger's /start gets THEIR own id to
  /// request access (never the allowlist, never a turn); everything else is the private-bot line.
  func denyAccess(
    _ command: Command,
    rawUpdate: RawUpdate,
    message: IncomingMessage
  ) async -> HandleOutcome {
    if case .start = command {
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        chatId: message.chatId,
        text: Self.unauthorizedStartText(userId: message.userId)
      )
    }
    return await replies.sendPrivateBot(updateId: rawUpdate.updateId, chatId: message.chatId)
  }

  // swiftlint:disable:next cyclomatic_complexity
  func routeAllowed(
    _ command: Command,
    rawUpdate: RawUpdate,
    message: IncomingMessage
  ) async throws(RoutingHalt) -> HandleOutcome {
    switch command {
    case .start:
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        chatId: message.chatId,
        text: Self.welcomeText
      )
    case .help:
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        chatId: message.chatId,
        text: CommandReplies.help
      )
    case .doctor:
      return await sendHealth(rawUpdate: rawUpdate, message: message, section: nil)
    case .mcp:
      return await sendHealth(rawUpdate: rawUpdate, message: message, section: .mcp)
    case .skills:
      return await sendSkills(rawUpdate: rawUpdate, message: message)
    case .stop:
      return try await commandHandlers.stop(rawUpdate: rawUpdate, message: message)
    case .new:
      return try await commandHandlers.new(rawUpdate: rawUpdate, message: message)
    case .remember(let rememberCommand):
      return try await commandHandlers.remember(
        rawUpdate: rawUpdate,
        message: message,
        command: rememberCommand
      )
    case .memory(let memoryCommand):
      return try await commandHandlers.memory(
        rawUpdate: rawUpdate,
        message: message,
        command: memoryCommand
      )
    case .schedule(let scheduleCommand):
      return try await routeSchedule(scheduleCommand, rawUpdate: rawUpdate, message: message)
    case .pause(let jobId):
      return try await scheduleHandlers.pause(rawUpdate: rawUpdate, message: message, jobId: jobId)
    case .resume(let jobId):
      return try await scheduleHandlers.resume(
        rawUpdate: rawUpdate,
        message: message,
        jobId: jobId
      )
    case .runNow(let jobId):
      return try await scheduleHandlers.runNow(
        rawUpdate: rawUpdate,
        message: message,
        jobId: jobId
      )
    case .cancelJob(let jobId):
      return try await scheduleHandlers.cancelJob(
        rawUpdate: rawUpdate,
        message: message,
        jobId: jobId
      )
    case .plain(let plainText):
      return try await routePlain(plainText, rawUpdate: rawUpdate, message: message)
    }
  }

  /// The health reply — the whole report, or one section of it. `/mcp` is status-only, and routing
  /// it through this same report is what keeps it that way: the router has no MCP surface beyond
  /// rendering what the daemon already holds.
  func sendHealth(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    section: DoctorGroup?
  ) async -> HandleOutcome {
    let report = await doctor.report()
    return await replies.sendCanned(
      updateId: rawUpdate.updateId,
      chatId: message.chatId,
      text: section.map(report.renderTelegramGroup) ?? report.renderTelegramSummary()
    )
  }

  /// A fresh scan on every request keeps the owner view aligned with the workspace on disk. The
  /// router only renders it; scanning and presentation remain owned by their existing seams.
  func sendSkills(rawUpdate: RawUpdate, message: IncomingMessage) async -> HandleOutcome {
    let scan = await doctor.scanSkills()
    let diagnostics = SkillDiagnostics(scan: scan, skillsCap: ContextBudget.default.skillsCap)
    return await replies.sendCanned(
      updateId: rawUpdate.updateId,
      chatId: message.chatId,
      text: diagnostics.render()
    )
  }

  func routeSchedule(
    _ scheduleCommand: ScheduleCommand,
    rawUpdate: RawUpdate,
    message: IncomingMessage
  ) async throws(RoutingHalt) -> HandleOutcome {
    switch scheduleCommand {
    case .create(let text):
      return try await scheduleHandlers.create(rawUpdate: rawUpdate, message: message, text: text)
    case .list:
      return try await scheduleHandlers.list(rawUpdate: rawUpdate, chatId: message.chatId)
    }
  }

  /// Plain text first offers itself to any parked confirmation for the session; only an
  /// unclaimed message becomes a durable turn.
  func routePlain(
    _ text: String,
    rawUpdate: RawUpdate,
    message: IncomingMessage
  ) async throws(RoutingHalt) -> HandleOutcome {
    if let resolved = try await confirmations.resolve(
      rawUpdate: rawUpdate,
      message: message,
      text: text
    ) {
      return resolved
    }
    return try await turnDispatch.dispatch(rawUpdate: rawUpdate, message: message, text: text)
  }
}

// MARK: - Unauthorized Reply

extension MessageRouter {
  /// The `/start` refusal doubles as onboarding: its last line is pasteable into clawd.env.
  static func unauthorizedStartText(userId: Int64) -> String {
    """
    This is a private bot. Your Telegram user ID is \(userId). To authorize it, the owner \
    adds this line to clawd.env and restarts clawd:
    CLAW_ALLOWLIST=\(userId)
    """
  }
}
