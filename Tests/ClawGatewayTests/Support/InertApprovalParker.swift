import ClawCore
import Logging

@testable import ClawGateway

/// Test parker: HOLDS the session lane by awaiting the coordinator, then returns without resuming.
/// Suites that only need a run to park — never to resume — use this instead of the real
/// `ApprovalWaiter`, which production wires at the composition root.
struct InertApprovalParker: ApprovalParking {
  private let coordinator: ApprovalCoordinator
  private let logger: Logger

  init(coordinator: ApprovalCoordinator, logger: Logger = Logger(label: "approval.parker")) {
    self.coordinator = coordinator
    self.logger = logger
  }

  func park(
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
