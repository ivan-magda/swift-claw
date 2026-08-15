import ClawCore
import ClawTestSupport
import ServiceLifecycleTestKit
import Testing

@testable import ClawGateway

@Suite struct SandboxLifecycleServiceTests {
  @Test func endingTheServiceRunsBackendShutdownOnce() async throws {
    // given
    let backend = FakeExecutionBackend()
    let service = SandboxLifecycleService(maintenance: backend)

    // when — the service parks until graceful shutdown, then tears the backend down
    let finished = CompletionFlag()
    try await testGracefulShutdown { trigger in
      let running = Task {
        try await service.run()
        await finished.markDone()
      }
      for _ in 0..<50 {
        await Task.yield()
      }

      // then — still parked, so the teardown cannot have run
      #expect(await finished.done == false)
      #expect(await backend.shutdownCallCount() == 0)

      trigger.triggerGracefulShutdown()
      try await running.value
      #expect(await backend.shutdownCallCount() == 1)
    }
  }
}
