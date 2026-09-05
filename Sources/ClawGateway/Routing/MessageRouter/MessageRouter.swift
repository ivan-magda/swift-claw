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
  let botUsername: String?
  private let addressing: AddressingResolver

  private let accessControl: AccessControl
  let replies: ReplySender

  let commandHandlers: CommandHandlers
  let scheduleHandlers: ScheduleHandlers
  let learningHandlers: LearningHandlers?
  let confirmations: ConfirmationResolver
  let turnDispatch: TurnDispatch
  let approvalCallbacks: ApprovalCallbackHandler?
  let feedbackCallbacks: FeedbackCallbackHandler?
  let feedbackChallenges: FeedbackChallengeHandler?
  let voice: (any VoiceMessageTranscribing)?
  let images: (any ImageMessageHandling)?
  let typing: (any TypingIndicator)?

  let doctor: any DoctorReporting
  let logger: Logger

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
    learningOutboxSignal: OutboxSignal? = nil,
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
      outboxSignal: learningOutboxSignal,
      redactor: learningRedactor,
      sessionMessages: sessionMessages,
      pendingConfirmations: pendingConfirmations,
      replies: replies,
      now: now
    )
    self.confirmations = ConfirmationResolver(
      sessionMessages: sessionMessages,
      pendingConfirmations: pendingConfirmations,
      memoryCommands: memoryCommands,
      learningReset: learningStore,
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

// MARK: - Construction

private extension MessageRouter {
  static func makeLearningHandlers(
    store: (any ScheduledLearningStore)?,
    outboxSignal: OutboxSignal?,
    redactor: SecretRedactor?,
    sessionMessages: any SessionMessageStore,
    pendingConfirmations: PendingConfirmationRegistry,
    replies: ReplySender,
    now: @escaping @Sendable () -> Date
  ) -> LearningHandlers? {
    guard let store, let redactor else {
      return nil
    }
    return LearningHandlers(
      learning: store,
      redactor: redactor,
      sessionMessages: sessionMessages,
      pendingConfirmations: pendingConfirmations,
      replies: replies,
      now: now,
      outboxSignal: outboxSignal
    )
  }
}

// MARK: - Routing

private extension MessageRouter {
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
}
