import ClawCore
import Testing

@testable import ClawGateway

@Suite
struct ApprovalCoordinatorTests {
  @Test
  func awaitBeforeSignalDeliversWhenSignalArrives() async {
    // given — a waiter registers first
    let coordinator = ApprovalCoordinator()
    async let resolution = coordinator.awaitResolution(approvalID: 42)

    // when — the signal arrives afterwards
    await coordinator.signal(.approved, forApprovalID: 42)

    // then
    #expect(await resolution == .approved)
  }

  @Test
  func signalBeforeAwaitIsBufferedAndReturnsImmediately() async {
    // given — the resolution lands BEFORE the waiter registers (the suspend-commit race)
    let coordinator = ApprovalCoordinator()
    await coordinator.signal(.denied(.expired), forApprovalID: 7)

    // when — the waiter registers late
    let resolution = await coordinator.awaitResolution(approvalID: 7)

    // then — the buffered signal is delivered, not lost
    #expect(resolution == .denied(.expired))
  }

  @Test
  func signalsAreKeyedPerApprovalID() async {
    // given
    let coordinator = ApprovalCoordinator()
    await coordinator.signal(.approved, forApprovalID: 1)
    await coordinator.signal(.denied(.cancelled), forApprovalID: 2)

    // when / then — each id resolves to its own buffered signal
    #expect(await coordinator.awaitResolution(approvalID: 2) == .denied(.cancelled))
    #expect(await coordinator.awaitResolution(approvalID: 1) == .approved)
  }
}
