import ClawCore
import ClawTestSupport
import Testing

@testable import ClawGateway

@Suite struct SandboxLifecycleServiceTests {
  @Test func endingTheServiceRunsBackendShutdownOnce() async throws {
    // given
    let backend = FakeExecutionBackend()
    let service = SandboxLifecycleService(maintenance: backend)

    // when — the service parks until the group cancels it
    let running = Task { try await service.run() }
    running.cancel()
    try await running.value

    // then
    #expect(await backend.shutdownCallCount() == 1)
  }
}
