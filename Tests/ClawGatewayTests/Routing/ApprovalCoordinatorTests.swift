import ClawCore
import Testing

@testable import ClawGateway

@Suite struct ApprovalCoordinatorTests {
  @Test func awaitBeforeSignalDeliversWhenSignalArrives() async {
    // given — a waiter registers first
    let coordinator = ApprovalCoordinator()
    async let resolution = coordinator.awaitResolution(approvalId: 42)

    // when — the signal arrives afterwards
    await coordinator.signal(approvalId: 42, .approved)

    // then
    #expect(await resolution == .approved)
  }

  @Test func signalBeforeAwaitIsBufferedAndReturnsImmediately() async {
    // given — the resolution lands BEFORE the waiter registers (the suspend-commit race)
    let coordinator = ApprovalCoordinator()
    await coordinator.signal(approvalId: 7, .denied(.expired))

    // when — the waiter registers late
    let resolution = await coordinator.awaitResolution(approvalId: 7)

    // then — the buffered signal is delivered, not lost
    #expect(resolution == .denied(.expired))
  }

  @Test func signalsAreKeyedPerApprovalId() async {
    // given
    let coordinator = ApprovalCoordinator()
    await coordinator.signal(approvalId: 1, .approved)
    await coordinator.signal(approvalId: 2, .denied(.cancelled))

    // when / then — each id resolves to its own buffered signal
    #expect(await coordinator.awaitResolution(approvalId: 2) == .denied(.cancelled))
    #expect(await coordinator.awaitResolution(approvalId: 1) == .approved)
  }
}
