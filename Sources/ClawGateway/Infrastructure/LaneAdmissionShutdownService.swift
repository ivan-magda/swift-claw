import ClawAgent
import Logging
import ServiceLifecycle

/// The lane-quiescing step of graceful shutdown, registered LAST in the service graph so
/// ServiceLifecycle — which shuts services down in reverse array order — cancels it FIRST. Its
/// synchronous graceful-shutdown handler closes the lock-backed admission gate the instant shutdown
/// begins (even mid-turn) and wakes the operation; the operation then cancels every registered turn
/// and awaits the registry's bounded drain, recording one outcome. The drain is awaited, never
/// cancelled: it is bounded solely by `drainTimeout`, and cancelling its join would leak the
/// deadline child — the registry's pinned contract.
public struct LaneAdmissionShutdownService: Service {
  private let lanes: SessionLaneRegistry
  private let outcome: LaneShutdownOutcome
  private let drainTimeout: Duration
  private let clock: any Clock<Duration>
  private let logger: Logger

  public init(
    lanes: SessionLaneRegistry,
    outcome: LaneShutdownOutcome,
    drainTimeout: Duration,
    clock: any Clock<Duration> = ContinuousClock(),
    logger: Logger
  ) {
    self.lanes = lanes
    self.outcome = outcome
    self.drainTimeout = drainTimeout
    self.clock = clock
    self.logger = logger
  }

  public func run() async throws {
    // A one-shot wake channel: the synchronous handler yields once shutdown begins, so the operation
    // stays parked (doing nothing, admitting nothing new) until then. `bufferingNewest(1)` means a
    // shutdown that fires before the operation reaches `next()` is still delivered.
    let (wake, wakeContinuation) = AsyncStream.makeStream(
      of: Void.self,
      bufferingPolicy: .bufferingNewest(1)
    )

    await withGracefulShutdownHandler {
      var iterator = wake.makeAsyncIterator()
      _ = await iterator.next()
    } onGracefulShutdown: {
      // Synchronous and nonblocking: stop admitting at once — touching no actor state — then wake the
      // operation. Draining is deliberately NOT done here; the handler must not block the shutdown
      // signal.
      lanes.closeAdmission()
      wakeContinuation.yield(())
      wakeContinuation.finish()
    }

    // Cancellation-insensitive from here: cancel every registered turn, then await the bounded drain.
    await lanes.stopAcceptingAndCancel()
    let result = await lanes.drain(timeout: drainTimeout, clock: clock)
    await outcome.record(result)

    switch result {
    case .drained:
      logger.info("session lanes drained")
    case .timedOut(let activeRunIDs):
      // A drain timeout is a failure path, not a clean shutdown: report the runs still in flight so
      // the caller can exit before tearing dependent resources down underneath them.
      logger.error(
        "session lane drain timed out; runs still in flight: \(activeRunIDs)"
      )
    }
  }
}
