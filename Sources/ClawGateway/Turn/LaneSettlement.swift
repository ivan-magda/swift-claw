import ClawCore
import Foundation
import Logging

/// The lane closure's settlement tail, and the only in-process owner of a deferred settlement.
///
/// `RunStore` leaves `settled_at` null wherever a later primary fact is still possible —
/// cancellation, supersession, the approval crash window. A lane closure can outlive its run's
/// terminal transition, so it ends here and the run rejoins the learning loop as soon as the lane
/// unwinds. Boot reconciliation is the crash backstop, not the ordinary path: a settlement that
/// waited for the next daemon start would strand the run for as long as the daemon stays up.
///
/// Shared rather than inlined because there are two such closures — `TurnEnqueuer`'s turn work and
/// `ApprovalBootReconciler`'s re-park, which enqueues onto the same registry directly. A tail
/// present in only one of them is the bug this type exists to make impossible.
struct LaneSettlement: Sendable {
  private let learning: ScheduledLearningService?
  private let now: @Sendable () -> Date
  private let logger: Logger

  init(
    learning: ScheduledLearningService?,
    now: @escaping @Sendable () -> Date,
    logger: Logger
  ) {
    self.learning = learning
    self.now = now
    self.logger = logger
  }

  /// Settles, then notifies — both halves in the one tail every lane exit passes through, so no
  /// future exit path can carry the settlement and skip the sealing that follows it.
  ///
  /// Best-effort and non-throwing: the store settles only a bound run that is terminal and still
  /// open, so this is safe to call on every lane exit, and a failure leaves the run to boot
  /// reconciliation rather than failing a turn that has already delivered its answer. Inert when
  /// the composition carries no learning service.
  ///
  /// `log` lets a caller pass its run-stamped logger so lifecycle greps by `run=<id>` keep working.
  func settle(runId: Int64, log: Logger? = nil) async {
    guard let learning else {
      return
    }
    await learning.settleAndNotify(runId: runId, now: now(), log: log ?? logger)
  }
}
