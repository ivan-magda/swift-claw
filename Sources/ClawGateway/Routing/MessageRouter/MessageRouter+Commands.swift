import ClawCore

// MARK: - Control Routing

extension MessageRouter {
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
}

// MARK: - Command Dispatch

private extension MessageRouter {
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
  /// there — all families that park are refused in `routeAllowed` — and skipping keeps it that
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
