import ClawCore
import Foundation
import Logging

/// The inbound plain-text → durable run bridge: fuses claim + persistence, then enqueues the
/// run and returns without awaiting it. Persistence failure prevents cursor advancement;
/// background turn failures are logged in-band by `TurnEnqueuer`.
struct TurnDispatch: Sendable {
  let sessionMessages: any SessionMessageStore

  let enqueuer: TurnEnqueuer
  let replies: ReplySender

  let now: @Sendable () -> Date
  let logger: Logger

  func dispatch(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    text: String
  ) async throws(RoutingHalt) -> HandleOutcome {
    let inbound = InboundMessage(
      updateId: rawUpdate.updateId,
      sessionKey: SessionKey.telegramDM(chatId: message.chatId),
      chatId: message.chatId,
      userId: message.userId,
      text: text,
      isEdited: message.isEdited,
      ts: now()
    )

    let claim = try await replies.perform(
      "inbound persist",
      updateId: rawUpdate.updateId,
      chatId: message.chatId
    ) {
      try sessionMessages.claimAndPersistInbound(inbound)
    }

    guard
      claim.newlyClaimed,
      let sessionId = claim.sessionId,
      let runId = claim.runId,
      let triggerMessageId = claim.triggerMessageId
    else {
      return replies.skipDuplicate(updateId: rawUpdate.updateId)
    }

    // The inbound → run bridge: the one INFO line that shows a real message was accepted and
    // which run it became. run/session/update ride as metadata so the whole lifecycle greps by
    // `run=<id>`; only the message SIZE is logged, never its text.
    var runLog = logger
    runLog[metadataKey: "run"] = "\(runId)"
    runLog[metadataKey: "session"] = "\(sessionId)"
    runLog[metadataKey: "update"] = "\(rawUpdate.updateId)"
    runLog.info(
      "message accepted; dispatching run (chars=\(text.count) edited=\(message.isEdited))"
    )

    await enqueuer.enqueue(
      runId: runId,
      sessionId: sessionId,
      chatId: message.chatId,
      triggerMessageId: triggerMessageId,
      log: runLog
    )

    return .processed
  }
}
