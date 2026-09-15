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
    approvalID: Int64,
    runID: Int64,
    sessionID: Int64,
    chatID: Int64,
    revalidatePolicyOnApprove: Bool
  ) async {
    let signal = await coordinator.awaitResolution(approvalID: approvalID)
    logger.debug(
      """
      approval \(approvalID) resolved as \(String(describing: signal)); \
      the waiter completes the run
      """
    )
  }
}
