import ClawCore

// MARK: - Control Routing

extension MessageRouter {
  func routeText(
    _ text: String,
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    mode: ChatMode
  ) async throws(RoutingHalt) -> HandleOutcome {
    if !conferenceProfile, mode == .direct, let feedbackChallenges {
      let consumed = try await feedbackChallenges.consumeIfOpen(
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
    if !conferenceProfile, FeedbackKeyboard.belongsToDomain(callback.data) {
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
}

// MARK: - Command Dispatch

private extension MessageRouter {
  static let conferenceCommandRefusal = """
    This conference bot only accepts challenge messages plus /start, /help, /new and /stop.
    """

  static let conferenceHelp = """
    Ask for today's case, send your own proposed solution, or ask for your submission status.
    """

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  func routeAllowed(
    _ command: Command,
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    mode: ChatMode
  ) async throws(RoutingHalt) -> HandleOutcome {
    if conferenceProfile, !conferenceCommandAllowed(command) {
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        target: .reply(to: message, mode: mode),
        text: Self.conferenceCommandRefusal
      )
    }

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
        text: conferenceProfile ? Self.conferenceWelcomeText : Self.welcomeText
      )
    case .help:
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        target: .reply(to: message, mode: mode),
        text: conferenceProfile ? Self.conferenceHelp : CommandReplies.help(mode: mode)
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

  func conferenceCommandAllowed(_ command: Command) -> Bool {
    switch command {
    case .start, .help, .stop, .new, .plain:
      return true
    default:
      return false
    }
  }

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

  func routePlain(
    _ text: String,
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    mode: ChatMode
  ) async throws(RoutingHalt) -> HandleOutcome {
    if mode == .direct, !conferenceProfile {
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
