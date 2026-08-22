import ClawCore
import Foundation
import Logging

/// The inbound plain-text → durable run bridge: fuses claim + persistence, then enqueues the
/// run and returns without awaiting it. Persistence failure prevents cursor advancement;
/// background turn failures are logged in-band by `TurnEnqueuer`.
///
/// `observe` is the same bridge minus the run, for a group message the bot overheard rather than
/// was asked. Both paths mint the key and the claim the same way, so a room's transcript is one
/// sequence whether or not the bot answered any given line.
struct TurnDispatch: Sendable {
  let sessionMessages: any SessionMessageStore

  let enqueuer: TurnEnqueuer
  let replies: ReplySender

  /// Where an inbound photo's bytes wait for the turn that replays them.
  let imageCache: ImageCache

  let now: @Sendable () -> Date
  let logger: Logger

  func dispatch(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    text: String,
    mode: ChatMode = .direct,
    provenance: Provenance = .trusted,
    image: ImagePart? = nil
  ) async throws(RoutingHalt) -> HandleOutcome {
    let inbound = InboundMessage(
      updateId: rawUpdate.updateId,
      sessionKey: SessionKey.telegram(for: message, mode: mode),
      chatId: message.chatId,
      userId: message.userId,
      text: text,
      isEdited: message.isEdited,
      provenance: provenance,
      telegramMessageId: message.messageId,
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

    // The claim is what mints the row id the bytes are keyed by, so the deposit can only happen
    // here — and it must land before the run is enqueued, or the turn it belongs to looks text-only.
    if let image {
      await imageCache.store(image, sessionId: sessionId, messageId: triggerMessageId)
    }

    // The inbound → run bridge: the one INFO line that shows a real message was accepted and
    // which run it became. run/session/update ride as metadata so the whole lifecycle greps by
    // `run=<id>`; only the message SIZE is logged, never its text.
    var runLog = logger
    runLog[metadataKey: "run"] = "\(runId)"
    runLog[metadataKey: "session"] = "\(sessionId)"
    runLog[metadataKey: "update"] = "\(rawUpdate.updateId)"
    runLog.info(
      """
      message accepted; dispatching run \
      (chars=\(text.count) edited=\(message.isEdited) image=\(image != nil))
      """
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
  /// Persists an overheard group message and returns, having said and run nothing. Silence is the
  /// contract even when the write fails: a room the bot was not talking to is told nothing about
  /// the daemon's disk, so the outcome alone carries the failure back to the poller.
  func observe(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    text: String,
    mode: ChatMode,
    provenance: Provenance = .trusted
  ) async -> HandleOutcome {
    let inbound = InboundMessage(
      updateId: rawUpdate.updateId,
      sessionKey: SessionKey.telegram(for: message, mode: mode),
      chatId: message.chatId,
      userId: message.userId,
      text: text,
      isEdited: message.isEdited,
      provenance: provenance,
      telegramMessageId: message.messageId,
      ts: now()
    )

    let claim: ClaimResult
    do {
      claim = try sessionMessages.claimAndPersistObserved(inbound)
    } catch StoreError.diskFull {
      logger.error("observed persist hit a full disk on update \(rawUpdate.updateId)")
      return .storageFull
    } catch {
      logger.error("observed persist failed for update \(rawUpdate.updateId): \(error)")
      return .transientFailure
    }

    guard claim.newlyClaimed else {
      return replies.skipDuplicate(updateId: rawUpdate.updateId)
    }

    logger.debug(
      "observed update \(rawUpdate.updateId) in chat \(message.chatId) (chars=\(text.count))"
    )
    return .processed
  }
}
