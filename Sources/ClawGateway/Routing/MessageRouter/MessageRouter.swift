import ClawAgent
import ClawCore
import Foundation
import Logging

/// Outcome of routing one update — tells the poller whether it may advance the offset.
public enum HandleOutcome: Sendable, Equatable {
  case processed
  case skipped
  case transientFailure
  case storageFull
}

/// Routes one inbound update through the configured access and command surface. The conference
/// profile is deliberately restrictive: it exists only on an isolated conference deployment and
/// admits participant DMs while suppressing owner-only operational command families.
public struct MessageRouter: Sendable {
  let botUsername: String?
  private let addressing: AddressingResolver

  private let accessControl: AccessControl
  let conferenceProfile: Bool
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
    conferenceProfile: Bool = false,
    coordinator: ApprovalCoordinator,
    doctor: any DoctorReporting,
    now: @escaping @Sendable () -> Date = { Date() },
    logger: Logger
  ) {
    self.botUsername = botIdentity?.username
    self.addressing = AddressingResolver(identity: botIdentity)

    self.accessControl = accessControl
    self.conferenceProfile = conferenceProfile
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
  static let conferenceWelcomeText = """
    Conference Coding Challenge is online. Ask for today's case, send your own proposal, \
    or ask for your submission status.
    """
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
