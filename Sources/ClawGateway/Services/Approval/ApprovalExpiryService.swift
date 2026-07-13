import ClawCore
import Foundation
import Logging
import ServiceLifecycle

/// The 60 s wall-clock expiry ticker. Each tick sweeps every `PENDING` approval whose
/// `expires_ts <= now` to `EXPIRED` — the CAS and its `approvalDenied`/`expired` audit ride the
/// store's single `sweepExpired` transaction — then signals the coordinator
/// so the parked waiter runs the exact Deny path (synthetic observation, run→FAILED, owner
/// notice, button disarm). This service owns NONE of that; it sweeps then signals. Wall-clock
/// comparison only (never tick-counting): the durable `expires_ts` is the real deadline, so a
/// late-landing tick still resolves the row correctly. Tick-level mutual exclusion is structural —
/// one instance, one sequential loop; cross-process exclusion is the startup flock.
public struct ApprovalExpiryService: Service {
  /// The tick grain — pinned 60 s, NOT config. Expiry is a liveness / bounded-state control
  /// (an unresolved approval must not pin a session lane indefinitely), not an attacker defense,
  /// so sub-minute precision buys nothing: the row's `expires_ts` is authoritative and the
  /// sweep compare is exact regardless of when the tick fires.
  public static let tickInterval: Duration = .seconds(60)

  private let approvals: any ApprovalStore

  private let coordinator: ApprovalCoordinator

  private let now: @Sendable () -> Date
  private let clock: any Clock<Duration>

  private let logger: Logger

  public init(
    approvals: any ApprovalStore,
    coordinator: ApprovalCoordinator,
    now: @escaping @Sendable () -> Date,
    clock: any Clock<Duration>,
    logger: Logger
  ) {
    self.approvals = approvals

    self.coordinator = coordinator

    self.now = now
    self.clock = clock

    self.logger = logger
  }

  public func run() async throws {
    logger.info("approval-expiry starting")
    await cancelWhenGracefulShutdown {
      // Immediate first tick (restart recovery — a row that aged out while the daemon was down
      // sweeps at once), then sleep between ticks; a thrown sleep is graceful shutdown, so break.
      while !Task.isCancelled {
        await tick()
        do {
          try await clock.sleep(for: Self.tickInterval)
        } catch {
          break
        }
      }
    }
    logger.info("approval-expiry stopped")
  }

  /// One sweep pass. Non-throwing by contract: the ticker must survive every store failure (the
  /// next tick retries) rather than crash the service group. The CAS + audit live in the store;
  /// this service only sweeps then signals — the waiter owns the observation, run transition,
  /// owner notice, and button disarm.
  func tick() async {
    let sweepTime = now()
    let expired: [Approval]
    do {
      expired = try approvals.sweepExpired(now: sweepTime)
    } catch {
      logger.error("approval-expiry sweep failed: \(error)")
      return
    }
    for approval in expired {
      await coordinator.signal(approvalId: approval.id, .denied(.expired))
    }
  }
}
