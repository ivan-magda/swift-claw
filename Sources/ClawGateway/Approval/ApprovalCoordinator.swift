import ClawCore
import Logging
import Synchronization

/// The process-local resolution of a durable approval. The `approvals` row stays the source of
/// truth; this only wakes the held lane.
public enum ApprovalSignal: Sendable, Equatable {
  case approved
  case denied(ApprovalDecision)
}

/// Process-local coordinator between a resolver (callback/ticker/command/boot) and the ONE lane
/// waiter parked on an approval. Signal buffering closes the race where a resolution lands between
/// the suspend commit and the waiter's registration: a signal with no waiter is retained and
/// delivered on the next `awaitResolution`.
public actor ApprovalCoordinator {
  private var waiters: [Int64: CheckedContinuation<ApprovalSignal?, Never>] = [:]
  private var buffered: [Int64: ApprovalSignal] = [:]

  public init() {}

  /// One waiter per approval id. A buffered signal (resolver won the race) returns immediately.
  /// Returns `nil` when the awaiting task is cancelled before a signal arrives (graceful shutdown /
  /// lane cancel): the continuation is resumed and its slot cleared so nothing leaks, and the
  /// durable row is left untouched for boot re-park to rebuild.
  public func awaitResolution(approvalId: Int64) async -> ApprovalSignal? {
    if let signal = buffered.removeValue(forKey: approvalId) {
      return signal
    }
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<ApprovalSignal?, Never>) in
        if Task.isCancelled {
          continuation.resume(returning: nil)
        } else {
          waiters[approvalId] = continuation
        }
      }
    } onCancel: {
      Task { await self.cancelWaiter(approvalId) }
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

  /// Resumes a still-parked waiter with `nil` on cancellation. A no-op if a `signal` already removed
  /// it (the resolver won the race), so a resolution is never dropped. Actor isolation guarantees
  /// the `waiters[id] = continuation` registration completes before this can observe the slot.
  private func cancelWaiter(_ approvalId: Int64) {
    if let continuation = waiters.removeValue(forKey: approvalId) {
      continuation.resume(returning: nil)
    }
  }
}

/// The seam `TurnRunner` (suspend) and boot re-park hand the lane hold to. `ApprovalWaiter` is the
/// real conformer — it awaits the coordinator, then performs the resume or deny. Kept a protocol so
/// the placeholder below can be wired without a forward dependency on the real waiter.
public protocol ApprovalParking: Sendable {
  func park(
    approvalId: Int64,
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    revalidatePolicyOnApprove: Bool
  ) async
}

/// Breaks the `turnRunner` ⇄ `approvalWaiter` construction cycle: `TurnRunner` needs a `parker`,
/// and the real parker (the waiter) needs `turnRunner` as its dispatcher. Adopted once during
/// composition, before the service group (or the first test update) runs.
public final class DeferredApprovalParker: ApprovalParking {
  private let wrapped = Mutex<(any ApprovalParking)?>(nil)

  public init() {}

  public func adopt(_ parker: any ApprovalParking) {
    wrapped.withLock { boxed in
      boxed = parker
    }
  }

  public func park(
    approvalId: Int64,
    runId: Int64,
    sessionId: Int64,
    chatId: Int64,
    revalidatePolicyOnApprove: Bool
  ) async {
    let parker = wrapped.withLock { boxed in
      boxed
    }
    await parker?.park(
      approvalId: approvalId,
      runId: runId,
      sessionId: sessionId,
      chatId: chatId,
      revalidatePolicyOnApprove: revalidatePolicyOnApprove
    )
  }
}

/// Placeholder: HOLDS the session lane by awaiting the coordinator, then returns without
/// resuming. The real resume/deny is `ApprovalWaiter`, which replaces this at the composition
/// root; until it is wired, production registers no ask-tier tool, so `park` is never reached in
/// production.
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
    logger.debug(
      "approval \(approvalId) resolved as \(String(describing: signal)); the waiter completes the run"
    )
  }
}
