import ClawCore
import Logging

/// The process-local resolution of a durable approval. The `approvals` row stays the source of
/// truth; this only wakes the held lane.
public enum ApprovalSignal: Sendable, Equatable {
  case approved
  case denied(ApprovalDecision)
}

/// Process-local coordinator between a resolver (callback/ticker/command/boot) and the ONE lane
/// waiter parked on an approval. Signal buffering closes the race where a resolution lands between
/// the suspend commit and the waiter's registration (§5.5): a signal with no waiter is retained and
/// delivered on the next `awaitResolution`.
public actor ApprovalCoordinator {
  private var waiters: [Int64: CheckedContinuation<ApprovalSignal, Never>] = [:]
  private var buffered: [Int64: ApprovalSignal] = [:]

  public init() {}

  /// One waiter per approval id. A buffered signal (resolver won the race) returns immediately.
  public func awaitResolution(approvalId: Int64) async -> ApprovalSignal {
    if let signal = buffered.removeValue(forKey: approvalId) {
      return signal
    }
    return await withCheckedContinuation { continuation in
      waiters[approvalId] = continuation
    }
  }

  /// Delivers to a registered waiter, or buffers until one registers (never dropped).
  public func signal(approvalId: Int64, _ signal: ApprovalSignal) {
    if let continuation = waiters.removeValue(forKey: approvalId) {
      continuation.resume(returning: signal)
    } else {
      buffered[approvalId] = signal
    }
  }
}

/// The seam `TurnRunner` (suspend) and boot re-park (Task 19) hand the lane hold to. `ApprovalWaiter`
/// (Tasks 16/19) is the real conformer — it awaits the coordinator, then performs the §6.3 resume or
/// §6.4 deny. Kept a protocol so Phase 2 wires the placeholder below without a forward dependency on
/// the Phase 3 waiter.
public protocol ApprovalParking: Sendable {
  func park(
    approvalId: Int64,
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    revalidatePolicyOnApprove: Bool
  ) async
}

/// Phase 2 placeholder: HOLDS the session lane by awaiting the coordinator, then returns without
/// resuming. Production Phase 2 registers no ask-tier tool, so `park` is never reached in
/// production; the real resume/deny is `ApprovalWaiter` (Tasks 16/19), which replaces this at the
/// composition root.
public struct InertApprovalParker: ApprovalParking {
  private let coordinator: ApprovalCoordinator
  private let logger: Logger

  public init(coordinator: ApprovalCoordinator, logger: Logger = Logger(label: "approval.parker")) {
    self.coordinator = coordinator
    self.logger = logger
  }

  public func park(
    approvalId: Int64,
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    revalidatePolicyOnApprove: Bool
  ) async {
    let signal = await coordinator.awaitResolution(approvalId: approvalId)
    logger.debug("approval \(approvalId) resolved as \(signal); Phase 3 waiter completes the run")
  }
}
