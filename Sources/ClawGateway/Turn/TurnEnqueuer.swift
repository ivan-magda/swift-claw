import ClawAgent
import ClawCore
import Logging

/// The one place a durable PENDING run becomes lane work (inbound turns, /runnow, the scheduler
/// tick). The lane closure cannot rethrow and `TurnDispatching.run` resolves every failure
/// in-band except `StoreError.diskFull` (D1), so this body is the single spelling of that
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
    let lane = await lanes.actor(for: sessionId)

    await lane.enqueue(runId: runId) {
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
  }

  /// A claimed scheduler/run-now fire is a first-class lane citizen — ordered and cancellable
  /// like any turn (D1).
  func enqueue(fire: ClaimedFire) async {
    await enqueue(
      runId: fire.runId,
      sessionId: fire.sessionId,
      chatId: fire.ownerChatId,
      triggerMessageId: fire.triggerMessageId
    )
  }
}
