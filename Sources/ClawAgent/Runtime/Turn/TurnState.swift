import ClawCore
import Logging

/// The facts fixed for one turn segment: whom it serves, when its wall clock ends, and the logger
/// every line of the turn goes through.
struct TurnFrame {
  let scope: TurnScope
  let deadline: ContinuousClock.Instant
  let startedAt: ContinuousClock.Instant
  let log: Logger
}
