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
    source: Provenance = .trusted,
    image: ImagePart? = nil
  ) async throws(RoutingHalt) -> HandleOutcome {
    let inbound = InboundMessage(
      updateID: rawUpdate.updateID,
      sessionKey: SessionKey.telegram(for: message, mode: mode),
      chatID: message.chatID,
      userID: message.userID,
      text: mode.transcriptText(text, author: TranscriptAuthor(message: message)),
      isEdited: message.isEdited,
      provenance: mode.storedProvenance(of: source),
      telegramMessageID: message.messageID,
      ts: now()
    )

    let claim = try await replies.perform(
      "inbound persist",
      updateID: rawUpdate.updateID,
      target: .reply(to: message, mode: mode)
    ) {
      try sessionMessages.claimAndPersistInbound(inbound)
    }

    guard
      claim.newlyClaimed,
      let sessionID = claim.sessionID,
      let runID = claim.runID,
      let triggerMessageID = claim.triggerMessageID
    else {
      return replies.skipDuplicate(updateID: rawUpdate.updateID)
    }

    // The claim is what mints the row id the bytes are keyed by, so the deposit can only happen
    // here — and it must land before the run is enqueued, or the turn it belongs to looks text-only.
    if let image {
      await imageCache.store(image, sessionID: sessionID, messageID: triggerMessageID)
    }

    // The inbound → run bridge: the one INFO line that shows a real message was accepted and
    // which run it became. run/session/update ride as metadata so the whole lifecycle greps by
    // `run=<id>`; only the message SIZE is logged, never its text.
    var runLog = logger
    runLog[metadataKey: "run"] = "\(runID)"
    runLog[metadataKey: "session"] = "\(sessionID)"
    runLog[metadataKey: "update"] = "\(rawUpdate.updateID)"
    runLog.info(
      """
      message accepted; dispatching run \
      (chars=\(text.count) edited=\(message.isEdited) image=\(image != nil))
      """
    )

    await enqueuer.enqueue(
      runID: runID,
      sessionID: sessionID,
      chatID: message.chatID,
      triggerMessageID: triggerMessageID,
      log: runLog
    )

    return .processed
  }

  /// Persists an overheard group message and returns, having said and run nothing. Silence is the
  /// contract even when the write fails: a room the bot was not talking to is told nothing about
  /// the daemon's disk, so the outcome alone carries the failure back to the poller.
  func observe(rawUpdate: RawUpdate, message: IncomingMessage, text: String, mode: ChatMode) async
    -> HandleOutcome
  {
    let inbound = InboundMessage(
      updateID: rawUpdate.updateID,
      sessionKey: SessionKey.telegram(for: message, mode: mode),
      chatID: message.chatID,
      userID: message.userID,
      text: mode.transcriptText(text, author: TranscriptAuthor(message: message)),
      isEdited: message.isEdited,
      provenance: mode.storedProvenance(of: .trusted),
      telegramMessageID: message.messageID,
      ts: now()
    )

    let claim: ClaimResult
    do { claim = try sessionMessages.claimAndPersistObserved(inbound) } catch StoreError.diskFull {
      logger.error("observed persist hit a full disk on update \(rawUpdate.updateID)")
      return .storageFull
    } catch {
      logger.error("observed persist failed for update \(rawUpdate.updateID): \(error)")
      return .transientFailure
    }

    guard claim.newlyClaimed else {
      return replies.skipDuplicate(updateID: rawUpdate.updateID)
    }

    logger.debug(
      "observed update \(rawUpdate.updateID) in chat \(message.chatID) (chars=\(text.count))"
    )
    return .processed
  }
}
