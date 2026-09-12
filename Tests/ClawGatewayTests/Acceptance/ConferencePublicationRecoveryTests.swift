import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawGateway

@Suite struct ConferencePublicationRecoveryTests {
  @Test func transientPublicationFailureRetriesAfterRestartWithoutRerunningCoder() async throws {
    // given — the external publication may exist even though its response was lost.
    let fixture = try ConferenceWorkflowFixture(publicationFailures: 1)
    let answer = "Restore accessibility labels in the component."
    let origin = try fixture.origin(answer: answer)
    let prepared = try await fixture.service.prepareSubmission(answer: answer)
    let queued = try await fixture.service.submit(prepared, context: origin.executionContext)
    let runner = Task { try await fixture.service.run() }
    let deadline = ContinuousClock.now + boundedTestPollCeiling
    while await fixture.publisher.attempts == 0 && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    runner.cancel()
    _ = await runner.result
    try #require(await fixture.publisher.attempts > 0)

    // when — recover against the same durable stores with a fresh workflow instance.
    let completed = try await fixture.finish(queued.id, using: fixture.restarted())

    // then
    #expect(completed.state == .completed)
    #expect(await fixture.publisher.attempts >= 2)
    #expect(await fixture.coder.admissions == 1)
    #expect(completed.pullRequestURL == "https://github.com/wowlocal/crew18-sim/pull/42")
    let notices = try fixture.outbox.pendingOutbound().filter {
      $0.payload.contains(queued.id.uuidString.lowercased())
    }
    #expect(notices.count == 1)
    #expect(notices.first?.chatId == origin.chatID)
  }
}
