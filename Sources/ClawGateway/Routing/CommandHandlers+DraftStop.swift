import ClawAgent
import ClawCore
import Foundation
import Logging

extension CommandHandlers {
  func stopDraft(_ stop: RawDraftStop, updateID: Int64) async throws(RoutingHalt) -> HandleOutcome {
    let startedAt = ContinuousClock.now
    let scope = await presentations?.stoppableRun(
      chatID: stop.chatID,
      threadID: stop.messageThreadID,
      draftID: stop.draftID
    )
    guard let scope else {
      logger.info("draft stop update \(updateID) draft \(stop.draftID): no active draft")
      return .skipped
    }

    let stopResult = try await replies.perform(
      "draft stop",
      updateID: updateID,
      target: .chat(stop.chatID)
    ) {
      try commands.applyDraftStop(updateID: updateID, runID: scope.runID, now: now())
    }

    guard stopResult.newlyClaimed else {
      logger.info("draft stop update \(updateID) run \(scope.runID): duplicate")
      return replies.skipDuplicate(updateID: updateID)
    }

    guard !stopResult.cancelledRunIDs.isEmpty else {
      logger.info("draft stop update \(updateID) run \(scope.runID): finished")
      return .processed
    }

    await applyStopEffects(stopResult)

    let acceptedAt = ContinuousClock.now
    let acceptanceMilliseconds = Self.milliseconds(startedAt.duration(to: acceptedAt))
    logger.info(
      "draft stop update \(updateID) run \(scope.runID): accepted in \(acceptanceMilliseconds) ms"
    )

    let acknowledgementAdmission = await lanes.afterRun(
      runID: scope.runID,
      sessionID: scope.sessionID
    ) {
      guard !Task.isCancelled else {
        return
      }

      let cleanupMilliseconds = Self.milliseconds(acceptedAt.duration(to: .now))
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

    if acknowledgementAdmission == .shuttingDown {
      logger.info("draft stop update \(updateID) run \(scope.runID): shutting down")
    }

    return .processed
  }
}

// MARK: - Diagnostic Timing

private extension CommandHandlers {
  static func milliseconds(_ duration: Duration) -> Int64 {
    let components = duration.components
    return components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
  }
}
