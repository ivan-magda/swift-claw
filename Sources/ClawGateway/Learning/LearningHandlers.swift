import ClawCore
import Foundation

/// Provider-free `/learning` reads plus the owner-confirmed reset barrier.
struct LearningHandlers: Sendable {
  let learning: any ScheduledLearningStore
  let redactor: SecretRedactor
  let sessionMessages: any SessionMessageStore
  let pendingConfirmations: PendingConfirmationRegistry
  let replies: ReplySender
  let now: @Sendable () -> Date
  let outboxSignal: OutboxSignal?

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
      guard let jobId else {
        return await replies.sendCanned(
          updateId: rawUpdate.updateId,
          target: .chat(message.chatId),
          text: CommandReplies.learningUsage
        )
      }
      return try await requestReset(jobId: jobId, rawUpdate: rawUpdate, message: message)
    }
  }

  private func requestReset(
    jobId: Int64,
    rawUpdate: RawUpdate,
    message: IncomingMessage
  ) async throws(RoutingHalt) -> HandleOutcome {
    let view = try await replies.perform(
      "learning reset view",
      updateId: rawUpdate.updateId,
      target: .chat(message.chatId)
    ) {
      try learning.learningView(jobId: jobId)
    }
    guard view.count == 1 else {
      return await replies.sendCanned(
        updateId: rawUpdate.updateId,
        target: .chat(message.chatId),
        text: CommandReplies.learningUnavailable
      )
    }
    switch view[0] {
    case .notFound, .unarmed:
      return await send(view: view, style: .detail, rawUpdate: rawUpdate, message: message)
    case .readable(let readable):
      return try await parkReset(
        jobId: jobId,
        label: readable.job.label,
        rawUpdate: rawUpdate,
        message: message
      )
    case .unreadable(let unreadable):
      return try await parkReset(
        jobId: jobId,
        label: unreadable.validatedLabel,
        rawUpdate: rawUpdate,
        message: message
      )
    }
  }

  private func parkReset(
    jobId: Int64,
    label: String?,
    rawUpdate: RawUpdate,
    message: IncomingMessage
  ) async throws(RoutingHalt) -> HandleOutcome {
    let claim = try await replies.perform(
      "learning reset claim",
      updateId: rawUpdate.updateId,
      target: .chat(message.chatId)
    ) {
      try sessionMessages.claimCommandUpdate(
        updateId: rawUpdate.updateId,
        sessionKey: SessionKey.telegramDM(chatId: message.chatId),
        now: now()
      )
    }
    guard case .claimed(let sessionId) = claim else {
      return replies.skipDuplicate(updateId: rawUpdate.updateId)
    }
    await pendingConfirmations.park(.learningReset(jobId: jobId), sessionId: sessionId)
    let prompt = LearningReplies.resetConfirmation(jobId: jobId, label: label)
    return await replies.sendCommandAck(
      updateId: rawUpdate.updateId,
      target: .chat(message.chatId),
      text: redactor.redact(prompt)
    )
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
    if let jobId, let outboxSignal,
      let outcome = try await promotionReply(
        jobId: jobId,
        view: view,
        rawUpdate: rawUpdate,
        message: message,
        signal: outboxSignal
      )
    {
      return outcome
    }
    return await send(view: view, style: style, rawUpdate: rawUpdate, message: message)
  }

  private func send(
    view: [JobLearningView],
    style: LearningSurface.Style,
    rawUpdate: RawUpdate,
    message: IncomingMessage
  ) async -> HandleOutcome {
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
