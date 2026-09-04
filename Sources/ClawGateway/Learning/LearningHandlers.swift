import ClawCore

/// Provider-free `/learning` reads plus the current unavailable reset reply.
struct LearningHandlers: Sendable {
  let learning: any ScheduledLearningStore
  let redactor: SecretRedactor
  let replies: ReplySender

  func handle(
    _ command: LearningCommand,
    rawUpdate: RawUpdate,
    message: IncomingMessage
  ) async throws(RoutingHalt) -> HandleOutcome {
    switch command {
    case .list:
      return try await read(
        jobId: nil,
        style: .list,
        rawUpdate: rawUpdate,
        message: message
      )
    case .detail(let jobId):
      return try await read(
        jobId: jobId,
        style: .detail,
        rawUpdate: rawUpdate,
        message: message
      )
    case .reset(let jobId):
      let text =
        jobId == nil ? CommandReplies.learningUsage : CommandReplies.learningResetUnavailable
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        target: .chat(message.chatId),
        text: text
      )
    }
  }

  private func read(
    jobId: Int64?,
    style: LearningSurface.Style,
    rawUpdate: RawUpdate,
    message: IncomingMessage
  ) async throws(RoutingHalt) -> HandleOutcome {
    let view = try await replies.perform(
      "learning view",
      updateId: rawUpdate.updateId,
      target: .chat(message.chatId)
    ) {
      try learning.learningView(jobId: jobId)
    }
    let rendered = LearningSurface.render(view, style: style)
    let safe = redactor.redact(rendered)
    let chunks = ReplySplitter.split(
      text: safe,
      limit: TelegramMessageLimits.maxPlainMessageCharacters
    )
    return await replies.sendCannedChunks(
      updateId: rawUpdate.updateId,
      target: .chat(message.chatId),
      texts: chunks
    )
  }
}
