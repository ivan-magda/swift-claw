import ClawTestSupport
import ServiceLifecycleTestKit
import Testing

@testable import ClawGateway

@Suite struct ConferenceShutdownTests {
  @Test func gracefulShutdownStopsTheQueueWithoutForcedCancellation() async throws {
    // given — the organizer must stop the daemon cleanly to switch the question of the day.
    let fixture = try ConferenceWorkflowFixture()
    let finished = CompletionFlag()
    try await testGracefulShutdown { trigger in
      let runner = Task {
        try await fixture.service.run()
        await finished.markDone()
      }

      // when — no direct Task.cancel: the production lifecycle signal must stop the loop.
      trigger.triggerGracefulShutdown()
      let deadline = ContinuousClock.now + boundedTestPollCeiling
      while await !finished.done && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      let stoppedGracefully = await finished.done
      runner.cancel()
      _ = await runner.result

      // then
      #expect(stoppedGracefully)
      #expect(await fixture.coder.admissions == 0)
    }
  }
}
