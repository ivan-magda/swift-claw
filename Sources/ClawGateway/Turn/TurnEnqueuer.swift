import ClawAgent
import ClawCore
import Logging

/// The one place a durable PENDING run becomes lane work (inbound turns, /runnow, the scheduler
/// tick). The lane closure cannot rethrow and `TurnDispatching.run` resolves every failure
/// in-band except `StoreError.diskFull`, so this body is the single spelling of that
/// contract.
struct TurnEnqueuer: Sendable {
  let lanes: SessionLaneRegistry
  let turns: any TurnDispatching
  let logger: Logger

  /// `log` lets the inbound path pass its run/session/update-stamped logger so lifecycle greps
  /// by `run=<id>` keep working; other initiators use the component logger.
  func enqueue(
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    triggerMessageId: Int64,
    log: Logger? = nil
  ) async {
    let runLog = log ?? logger
    let runner = turns

    let result = await lanes.enqueue(sessionID: sessionId, runID: runId) {
      do {
        try await runner.run(
          runId: runId,
          sessionId: sessionId,
          chatId: chatId,
          triggerMessageId: triggerMessageId
        )
      } catch StoreError.diskFull {
        runLog.error("run \(runId) stopped by storage full after enqueue")
      } catch {
        runLog.error("run \(runId) error (handled in-band): \(error)")
      }
    }

    if result == .shuttingDown {
      // Admission closed between the durable claim and the lane hop: the run stays PENDING for the
      // boot reconciler to recover on the next start rather than executing under a draining daemon.
      runLog.notice("run \(runId) not enqueued; lane admission is shutting down")
    }
  }

  /// A claimed scheduler/run-now fire is a first-class lane citizen — ordered and cancellable
  /// like any turn.
  func enqueue(fire: ClaimedFire) async {
    await enqueue(
      runId: fire.runId,
      sessionId: fire.sessionId,
      chatId: fire.ownerChatId,
      triggerMessageId: fire.triggerMessageId
    )
  }
}
