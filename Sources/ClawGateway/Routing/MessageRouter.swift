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
    delivery: any MessageDelivery,
    turnRunner: any TurnDispatching,
    lanes: SessionLaneRegistry,
    schedule: ScheduleSurface,
    approvalCallbacks: ApprovalCallbackHandler? = nil,
    now: @escaping @Sendable () -> Date = { Date() },
    logger: Logger
  ) {
    self.botUsername = botUsername
    self.accessControl = accessControl
    self.approvalCallbacks = approvalCallbacks
    self.logger = logger

    let replies = ReplySender(processed: processed, delivery: delivery, logger: logger)
    let enqueuer = TurnEnqueuer(lanes: lanes, turns: turnRunner, logger: logger)
    let turnDispatch = TurnDispatch(
      sessionMessages: sessionMessages,
      enqueuer: enqueuer,
      replies: replies,
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
      logger: logger
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
      turnDispatch: turnDispatch,
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
    // would .skipped and the cursor would advance past it (spec §6.1). The handler runs the §6.2
    // chain and returns a real HandleOutcome, so cursor semantics are unchanged.
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
    case .text(let text):
      let command = Command.parse(text, botUsername: botUsername)
      if isAllowed {
        return try await routeAllowed(command, rawUpdate: rawUpdate, message: message)
      }
      return await denyAccess(command, rawUpdate: rawUpdate, message: message)
    }
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
    case .schedule(.create(let text)):
      return try await scheduleHandlers.create(rawUpdate: rawUpdate, message: message, text: text)
    case .schedule(.list):
      return try await scheduleHandlers.list(rawUpdate: rawUpdate, chatId: message.chatId)
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
  }

  static func unauthorizedStartText(userId: Int64) -> String {
    """
    This is a private bot. Your Telegram user ID is \(userId). Ask the owner to add it to the allowlist.
    """
  }
}
