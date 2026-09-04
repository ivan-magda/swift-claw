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
  private let addressing: AddressingResolver

  private let accessControl: AccessControl
  private let replies: ReplySender

  private let commandHandlers: CommandHandlers
  private let scheduleHandlers: ScheduleHandlers
  private let learningHandlers: LearningHandlers?
  private let confirmations: ConfirmationResolver
  private let turnDispatch: TurnDispatch
  private let approvalCallbacks: ApprovalCallbackHandler?
  private let feedbackCallbacks: FeedbackCallbackHandler?
  private let feedbackChallenges: FeedbackChallengeHandler?
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
    botIdentity: BotIdentity?,
    accessControl: AccessControl,
    delivery: any MessageDelivery,
    turnRunner: any TurnDispatching,
    imageCache: ImageCache,
    lanes: SessionLaneRegistry,
    schedule: ScheduleSurface,
    /// The lane tail's settle-and-seal port; nil leaves a bound run's deferred settlement to the
    /// boot backstop and seals nothing.
    learning: ScheduledLearningService? = nil,
    learningStore: (any ScheduledLearningStore)? = nil,
    learningRedactor: SecretRedactor? = nil,
    approvalCallbacks: ApprovalCallbackHandler? = nil,
    feedbackCallbacks: FeedbackCallbackHandler? = nil,
    feedbackChallenges: FeedbackChallengeHandler? = nil,
    voice: (any VoiceMessageTranscribing)? = nil,
    images: (any ImageMessageHandling)? = nil,
    typing: (any TypingIndicator)? = nil,
    coordinator: ApprovalCoordinator,
    doctor: any DoctorReporting,
    now: @escaping @Sendable () -> Date = { Date() },
    logger: Logger
  ) {
    self.botUsername = botIdentity?.username
    self.addressing = AddressingResolver(identity: botIdentity)

    self.accessControl = accessControl
    self.approvalCallbacks = approvalCallbacks
    self.feedbackCallbacks = feedbackCallbacks
    self.feedbackChallenges = feedbackChallenges
    self.voice = voice
    self.images = images
    self.typing = typing

    self.doctor = doctor
    self.logger = logger

    let replies = ReplySender(processed: processed, delivery: delivery, logger: logger)
    let enqueuer = TurnEnqueuer(
      lanes: lanes,
      turns: turnRunner,
      learning: learning,
      now: now,
      logger: logger
    )
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
    self.learningHandlers = Self.makeLearningHandlers(
      store: learningStore,
      redactor: learningRedactor,
      replies: replies
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
  static func makeLearningHandlers(
    store: (any ScheduledLearningStore)?,
    redactor: SecretRedactor?,
    replies: ReplySender
  ) -> LearningHandlers? {
    guard let store, let redactor else {
      return nil
    }
    return LearningHandlers(learning: store, redactor: redactor, replies: replies)
  }

  func route(rawUpdate: RawUpdate) async throws(RoutingHalt) -> HandleOutcome {
    // A callback-only update normalizes to nil (no message/edited_message); without this branch it
    // would .skipped and the cursor would advance past it. The handler returns a real
    // HandleOutcome, so cursor semantics are unchanged.
    if let callback = rawUpdate.callback {
      return await routeCallback(callback, updateId: rawUpdate.updateId)
    }

    if let observed = noteObservedEvent(in: rawUpdate) {
      return observed
    }

    guard let message = IncomingMessage.normalize(from: rawUpdate) else {
      let dropped = rawUpdate.message ?? rawUpdate.editedMessage
      if dropped?.hasSenderChat == true {
        logger.debug("update \(rawUpdate.updateId) was sent on behalf of a chat, skipping")
      } else {
        logger.debug("update \(rawUpdate.updateId) has nothing actionable, skipping")
      }
      return .skipped
    }

    let decision = accessControl.decide(
      chatKind: message.chatKind,
      chatId: message.chatId,
      userId: message.userId
    )
    let mode: ChatMode
    switch decision {
    case .allowed(let allowed):
      mode = allowed
    case .denied(let denial):
      return await denyAccess(denial, rawUpdate: rawUpdate, message: message)
    }

    // Resolved once, ahead of the content switch, so an overheard photo or voice note is never
    // downloaded: in a room the bot listens to everything and acts only on what names it.
    guard addressing.isAddressed(message, mode: mode) else {
      return await observe(rawUpdate: rawUpdate, message: message, mode: mode)
    }

    switch message.content {
    case .unsupported(let kind):
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        target: .reply(to: message, mode: mode),
        text: Self.unsupportedMediaText(kind: kind)
      )
    case .photo(let attachment, let caption):
      return try await routeImage(
        attachment,
        caption: caption,
        rawUpdate: rawUpdate,
        message: message,
        mode: mode
      )
    case .voice(let attachment):
      return try await routeVoice(attachment, rawUpdate: rawUpdate, message: message, mode: mode)
    case .text(let text):
      return try await routeText(text, rawUpdate: rawUpdate, message: message, mode: mode)
    }
  }

  func routeText(
    _ text: String,
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    mode: ChatMode
  ) async throws(RoutingHalt) -> HandleOutcome {
    if mode == .direct, let feedbackChallenges {
      let consumed = try await feedbackChallenges.consumeIfOpen(
        text: text,
        rawUpdate: rawUpdate,
        message: message
      )
      if let consumed {
        return consumed
      }
    }
    let command = Command.parse(text, botUsername: botUsername)
    return try await routeAllowed(command, rawUpdate: rawUpdate, message: message, mode: mode)
  }

  func routeCallback(_ callback: RawCallback, updateId: Int64) async -> HandleOutcome {
    if FeedbackKeyboard.belongsToDomain(callback.data) {
      guard let feedbackCallbacks else {
        logger.debug("feedback callback update \(updateId) with no handler, skipping")
        return .skipped
      }
      return await feedbackCallbacks.handle(callback, updateId: updateId)
    }
    guard let approvalCallbacks else {
      logger.debug("callback update \(updateId) with no approval handler, skipping")
      return .skipped
    }
    return await approvalCallbacks.handle(callback, updateId: updateId)
  }

  /// The two updates the daemon can only take note of: its own membership changing, and Telegram
  /// replacing a chat id under a running configuration. Both run ahead of `normalize`, which would
  /// drop them as contentless — and the generic drop line is exactly the wrong trace for an event
  /// whose whole value is that an operator sees it.
  func noteObservedEvent(in rawUpdate: RawUpdate) -> HandleOutcome? {
    if let membership = rawUpdate.myChatMember {
      logMembership(membership, updateId: rawUpdate.updateId)
      return .skipped
    }
    let inbound = rawUpdate.message ?? rawUpdate.editedMessage
    if let inbound, let newChatId = inbound.migratedToChatId {
      logMigration(from: inbound, to: newChatId)
      return .skipped
    }
    return nil
  }

  /// Membership is observed, never acted on: an allowlist lives in configuration, so a room the
  /// bot was just added to still says nothing until an operator puts its id there. The log is how
  /// they learn the id, and how a silent removal or a rights change stops looking like a bug.
  func logMembership(_ membership: RawChatMemberUpdate, updateId: Int64) {
    let title = membership.chatTitle ?? "(untitled)"
    let actor = membership.actorDisplayName ?? membership.actorUserId.map(String.init) ?? "someone"
    let transition = "\(membership.oldStatus.apiValue) → \(membership.newStatus.apiValue)"
    let room = "chat \(membership.chatId) \"\(title)\" (\(membership.chatKind.apiValue))"
    switch membership.change {
    case .added:
      logger.notice("\(actor) added the bot to \(room): \(transition)")
    case .removed:
      logger.notice("\(actor) removed the bot from \(room): \(transition)")
    case .updated:
      logger.notice("\(actor) changed the bot's rights in \(room): \(transition)")
    case .unchanged:
      logger.debug("membership update \(updateId) changed nothing in \(room): \(transition)")
    }
  }

  /// Telegram replaces a group's chat id when it upgrades to a supergroup, and the old id stops
  /// existing. Rewriting `CLAW_GROUP_CHATS` at runtime would silently re-point an access grant at
  /// an id nobody approved, so the daemon does the opposite: it goes quiet in that room and says
  /// exactly what to edit.
  func logMigration(from message: RawMessage, to newChatId: Int64) {
    let title = message.chatTitle ?? "(untitled)"
    logger.error(
      """
      chat \(message.chatId) "\(title)" was upgraded to a supergroup and is now chat \(newChatId); \
      clawd will ignore it until CLAW_GROUP_CHATS lists \(newChatId) — update clawd.env and restart
      """
    )
  }

  /// The overheard branch. Only typed words are kept: a sticker, a voice note and a photo all
  /// need bytes the bot deliberately never fetched for a message that did not name it, so there is
  /// nothing of them to write down. The room's transcript therefore holds what was said in it, and
  /// no placeholder for what was shown.
  func observe(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    mode: ChatMode
  ) async -> HandleOutcome {
    guard case .text(let text) = message.content else {
      logger.debug(
        "update \(rawUpdate.updateId) in chat \(message.chatId) does not address the bot, skipping"
      )
      return .skipped
    }
    return await turnDispatch.observe(
      rawUpdate: rawUpdate,
      message: message,
      text: text,
      mode: mode
    )
  }

  func routeVoice(
    _ attachment: VoiceAttachment,
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    mode: ChatMode
  ) async throws(RoutingHalt) -> HandleOutcome {
    guard let voice else {
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        target: .reply(to: message, mode: mode),
        text: Self.unsupportedMediaText(kind: VoiceAttachment.mediaKindDescription)
      )
    }

    switch await voice.transcribe(attachment) {
    case .success(let transcript):
      return try await turnDispatch.dispatch(
        rawUpdate: rawUpdate,
        message: message,
        text: transcript,
        mode: mode,
        source: .untrusted
      )
    case .failure(.storageFull):
      return await replies.storageFull(target: .reply(to: message, mode: mode))
    case .failure(let failure):
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        target: .reply(to: message, mode: mode),
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
    mode: ChatMode
  ) async throws(RoutingHalt) -> HandleOutcome {
    guard let images else {
      return try await routeImageWithoutService(
        caption: caption,
        rawUpdate: rawUpdate,
        message: message,
        mode: mode
      )
    }

    // After both guards, so neither a stranger nor a disabled service is ever told the bot is
    // awake. Whether the pulse lands is not checked and cannot be: the action auto-expires
    // server-side, so one that never arrives is no reason to fail a photo the owner is waiting on.
    let target = DeliveryTarget.reply(to: message, mode: mode)
    await typing?.sendTyping(chatId: target.chatId, messageThreadId: target.messageThreadId)

    switch await images.materialize(attachment) {
    case .success(let image):
      return try await turnDispatch.dispatch(
        rawUpdate: rawUpdate,
        message: message,
        text: ImageMarkers.photoContent(caption: caption),
        mode: mode,
        source: .untrusted,
        image: image
      )
    case .failure(let failure):
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        target: .reply(to: message, mode: mode),
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
    message: IncomingMessage,
    mode: ChatMode
  ) async throws(RoutingHalt) -> HandleOutcome {
    guard let caption, caption.isEmpty == false else {
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        target: .reply(to: message, mode: mode),
        text: Self.unsupportedMediaText(kind: PhotoAttachment.mediaKindDescription)
      )
    }

    return try await turnDispatch.dispatch(
      rawUpdate: rawUpdate,
      message: message,
      text: ImageMarkers.photoContent(caption: caption),
      mode: mode,
      source: .untrusted
    )
  }

  /// Default-deny, applied ONCE for every update, before the content switch — so a refused photo
  /// or voice note is never downloaded. A stranger's /start gets THEIR own id to request access
  /// (never the allowlist, never a turn); every other DM refusal is the private-bot line, which is
  /// also all a stranger may learn about unsupported media.
  ///
  /// An unlisted chat is answered with silence but still logged: the id and title are the only way
  /// an operator can learn what to put in `CLAW_GROUP_CHATS`, since the bot says nothing in a room
  /// until that id is already configured.
  func denyAccess(
    _ denial: AccessDenial,
    rawUpdate: RawUpdate,
    message: IncomingMessage
  ) async -> HandleOutcome {
    switch denial {
    case .unlistedChat:
      let title = message.chatTitle ?? "(untitled)"
      logger.info(
        """
        ignoring update \(rawUpdate.updateId) from unlisted chat \(message.chatId) "\(title)" (\(message.chatKind.apiValue))
        """
      )
      return .skipped
    case .privateStranger:
      guard isStart(message.content) else {
        return await replies.sendPrivateBot(
          updateId: rawUpdate.updateId,
          target: .chat(message.chatId)
        )
      }
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        target: .chat(message.chatId),
        text: Self.unauthorizedStartText(userId: message.userId)
      )
    }
  }

  /// True only for `/start` — the one refusal that answers with the sender's own id.
  func isStart(_ content: IncomingMessage.Content) -> Bool {
    guard case .text(let text) = content else {
      return false
    }
    if case .start = Command.parse(text, botUsername: botUsername) {
      return true
    }
    return false
  }

  // A flat dispatch table: one case per command, each delegating in a line or two. Splitting it
  // would only hide half the table behind a name.
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  func routeAllowed(
    _ command: Command,
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    mode: ChatMode
  ) async throws(RoutingHalt) -> HandleOutcome {
    // Refused here rather than inside each handler, so a room never reaches the code that parks a
    // confirmation: with nothing parked, the next plain line in the topic is only ever a message.
    if mode == .group, command.isDirectOnly {
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        target: .reply(to: message, mode: mode),
        text: CommandReplies.directOnly
      )
    }

    switch command {
    case .start:
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        target: .reply(to: message, mode: mode),
        text: Self.welcomeText
      )
    case .help:
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        target: .reply(to: message, mode: mode),
        text: CommandReplies.help(mode: mode)
      )
    case .doctor:
      return await sendHealth(rawUpdate: rawUpdate, message: message, mode: mode, section: nil)
    case .mcp:
      return await sendHealth(rawUpdate: rawUpdate, message: message, mode: mode, section: .mcp)
    case .skills:
      return await sendSkills(rawUpdate: rawUpdate, message: message, mode: mode)
    case .stop:
      return try await commandHandlers.stop(rawUpdate: rawUpdate, message: message, mode: mode)
    case .new:
      return try await commandHandlers.new(rawUpdate: rawUpdate, message: message, mode: mode)
    case .remember(let rememberCommand):
      return try await commandHandlers.remember(
        rawUpdate: rawUpdate,
        message: message,
        command: rememberCommand,
        mode: mode
      )
    case .memory(let memoryCommand):
      return try await commandHandlers.memory(
        rawUpdate: rawUpdate,
        message: message,
        command: memoryCommand,
        mode: mode
      )
    case .schedule(let scheduleCommand):
      return try await routeSchedule(scheduleCommand, rawUpdate: rawUpdate, message: message)
    case .learning(let learningCommand):
      return try await routeLearning(
        learningCommand,
        rawUpdate: rawUpdate,
        message: message
      )
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
      return try await routePlain(plainText, rawUpdate: rawUpdate, message: message, mode: mode)
    }
  }

  /// The health reply — the whole report, or one section of it. `/mcp` is status-only, and routing
  /// it through this same report is what keeps it that way: the router has no MCP surface beyond
  /// rendering what the daemon already holds.
  func sendHealth(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    mode: ChatMode,
    section: DoctorGroup?
  ) async -> HandleOutcome {
    let report = await doctor.report()
    return await replies.sendCanned(
      updateId: rawUpdate.updateId,
      target: .reply(to: message, mode: mode),
      text: section.map(report.renderTelegramGroup) ?? report.renderTelegramSummary()
    )
  }

  /// A fresh scan on every request keeps the owner view aligned with the workspace on disk. The
  /// router only renders it; scanning and presentation remain owned by their existing seams.
  func sendSkills(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    mode: ChatMode
  ) async -> HandleOutcome {
    let scan = await doctor.scanSkills()
    let diagnostics = SkillDiagnostics(scan: scan, skillsCap: ContextBudget.default.skillsCap)
    return await replies.sendCanned(
      updateId: rawUpdate.updateId,
      target: .reply(to: message, mode: mode),
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

  func routeLearning(
    _ command: LearningCommand,
    rawUpdate: RawUpdate,
    message: IncomingMessage
  ) async throws(RoutingHalt) -> HandleOutcome {
    guard let learningHandlers else {
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        target: .chat(message.chatId),
        text: CommandReplies.learningUnavailable
      )
    }
    return try await learningHandlers.handle(command, rawUpdate: rawUpdate, message: message)
  }

  /// Plain text first offers itself to any parked confirmation for the session; only an
  /// unclaimed message becomes a durable turn.
  ///
  /// A room skips the offer outright instead of being trusted to come up empty. Nothing can park
  /// there — the two families that park are refused in `routeAllowed` — and skipping keeps it that
  /// way even if a third one is ever added: a "yes" typed in a topic is just a word.
  func routePlain(
    _ text: String,
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    mode: ChatMode
  ) async throws(RoutingHalt) -> HandleOutcome {
    if mode == .direct {
      let resolved = try await confirmations.resolve(
        rawUpdate: rawUpdate,
        message: message,
        text: text
      )
      if let resolved {
        return resolved
      }
    }
    return try await turnDispatch.dispatch(
      rawUpdate: rawUpdate,
      message: message,
      text: text,
      mode: mode
    )
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
