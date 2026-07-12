import ClawCore
import ClawTestSupport
import Testing

@testable import ClawGateway

@Suite struct SandboxLifecycleServiceTests {
  @Test func endingTheServiceRunsBackendShutdownOnce() async throws {
    // given
    let backend = FakeExecutionBackend()
    let service = SandboxLifecycleService(
      maintenance: backend,
      clock: ScriptedClock { duration in
        #expect(duration == SandboxLifecycleService.idleInterval)
        await Task.yield()
        throw CancellationError()
      }
    )

    // when
    try await service.run()

    // then
    #expect(await backend.shutdownCallCount() == 1)
  }
}
