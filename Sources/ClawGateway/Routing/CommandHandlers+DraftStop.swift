import ClawCore
import Foundation

extension CommandHandlers {
  func stopDraft(_ stop: RawDraftStop, updateID: Int64) async throws(RoutingHalt) -> HandleOutcome {
    let entered = ContinuousClock.now
    guard let scope = await presentations?.stoppableRun(
      chatID: stop.chatID,
      threadID: stop.messageThreadID,
      draftID: stop.draftID
    )
    else {
      logger.info("draft stop update \(updateID) draft \(stop.draftID): no active draft")
      return .skipped
    }
    let result = try await replies.perform(
      "draft stop",
      updateID: updateID,
      target: .chat(stop.chatID)
    ) {
      try commands.applyDraftStop(updateID: updateID, runID: scope.runID, now: now())
    }
    guard result.newlyClaimed else {
      logger.info("draft stop update \(updateID) run \(scope.runID): duplicate")
      return replies.skipDuplicate(updateID: updateID)
    }
    guard !result.cancelledRunIDs.isEmpty else {
      logger.info("draft stop update \(updateID) run \(scope.runID): finished")
      return .processed
    }

    await applyStopEffects(result)
    let accepted = ContinuousClock.now
    let acceptanceMilliseconds = Self.milliseconds(entered.duration(to: accepted))
    logger.info(
      "draft stop update \(updateID) run \(scope.runID): accepted in \(acceptanceMilliseconds) ms"
    )
    let admission = await lanes.afterRun(runID: scope.runID, sessionID: scope.sessionID) {
      guard !Task.isCancelled else {
        return
      }
      let cleanupMilliseconds = Self.milliseconds(accepted.duration(to: .now))
      logger.info(
        """
        draft stop update \(updateID) run \(scope.runID): \
        cleanup finished in \(cleanupMilliseconds) ms
        """
      )
      _ = await replies.sendCommandAck(
        updateID: updateID,
        target: .chat(stop.chatID),
        text: CommandReplies.stopped
      )
    }
    if admission == .shuttingDown {
      logger.info("draft stop update \(updateID) run \(scope.runID): shutting down")
    }
    return .processed
  }
}

// MARK: - Diagnostic Timing

private extension CommandHandlers {
  static func milliseconds(_ duration: Duration) -> Int64 {
    let parts = duration.components
    return parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000
  }
}
