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

  func handle(_ command: LearningCommand, rawUpdate: RawUpdate, message: IncomingMessage)
    async throws(RoutingHalt) -> HandleOutcome
  {
    switch command {
    case .list:
      return try await read(jobID: nil, style: .list, rawUpdate: rawUpdate, message: message)
    case .detail(let jobID):
      return try await read(jobID: jobID, style: .detail, rawUpdate: rawUpdate, message: message)
    case .reset(let jobID):
      guard let jobID else {
        return await replies.sendCanned(
          updateID: rawUpdate.updateID,
          target: .chat(message.chatID),
          text: CommandReplies.learningUsage
        )
      }
      return try await requestReset(jobID: jobID, rawUpdate: rawUpdate, message: message)
    }
  }

  private func requestReset(jobID: Int64, rawUpdate: RawUpdate, message: IncomingMessage)
    async throws(RoutingHalt) -> HandleOutcome
  {
    let view = try await replies.perform(
      "learning reset view",
      updateID: rawUpdate.updateID,
      target: .chat(message.chatID)
    ) {
      try learning.learningView(jobID: jobID)
    }
    guard view.count == 1 else {
      return await replies.sendCanned(
        updateID: rawUpdate.updateID,
        target: .chat(message.chatID),
        text: CommandReplies.learningUnavailable
      )
    }
    switch view[0] {
    case .notFound, .unarmed:
      return await send(view: view, style: .detail, rawUpdate: rawUpdate, message: message)
    case .readable(let readable):
      return try await parkReset(
        jobID: jobID,
        label: readable.job.label,
        rawUpdate: rawUpdate,
        message: message
      )
    case .unreadable(let unreadable):
      return try await parkReset(
        jobID: jobID,
        label: unreadable.validatedLabel,
        rawUpdate: rawUpdate,
        message: message
      )
    }
  }

  private func parkReset(
    jobID: Int64,
    label: String?,
    rawUpdate: RawUpdate,
    message: IncomingMessage
  ) async throws(RoutingHalt) -> HandleOutcome {
    let claim = try await replies.perform(
      "learning reset claim",
      updateID: rawUpdate.updateID,
      target: .chat(message.chatID)
    ) {
      try sessionMessages.claimCommandUpdate(
        updateID: rawUpdate.updateID,
        sessionKey: SessionKey.telegramDM(chatID: message.chatID),
        now: now()
      )
    }
    guard case .claimed(let sessionID) = claim else {
      return replies.skipDuplicate(updateID: rawUpdate.updateID)
    }
    await pendingConfirmations.park(.learningReset(jobID: jobID), sessionID: sessionID)
    let prompt = LearningReplies.resetConfirmation(jobID: jobID, label: label)
    return await replies.sendCommandAck(
      updateID: rawUpdate.updateID,
      target: .chat(message.chatID),
      text: redactor.redact(prompt)
    )
  }

  private func read(
    jobID: Int64?,
    style: LearningSurface.Style,
    rawUpdate: RawUpdate,
    message: IncomingMessage
  ) async throws(RoutingHalt) -> HandleOutcome {
    let view = try await replies.perform(
      "learning view",
      updateID: rawUpdate.updateID,
      target: .chat(message.chatID)
    ) {
      try learning.learningView(jobID: jobID)
    }
    if
      let jobID,
      let outboxSignal,
      let outcome = try await promotionReply(
        jobID: jobID,
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
      updateID: rawUpdate.updateID,
      target: .chat(message.chatID),
      texts: chunks
    )
  }
}
