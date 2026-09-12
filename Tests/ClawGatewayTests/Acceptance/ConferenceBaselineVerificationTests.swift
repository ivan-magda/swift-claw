import ClawCore
import Foundation
import Testing

@testable import ClawGateway

@Suite struct ConferenceBaselineVerificationTests {
  @Test func mismatchedObservedBaselineNeverReachesPublisher() async throws {
    // given — a successful Coder report is not evidence that it used the approved baseline.
    let fixture = try ConferenceWorkflowFixture(observedBaseline: String(repeating: "a", count: 40))
    let answer = "Use an actor for accessibility state."
    let origin = try fixture.origin(answer: answer)
    let prepared = try await fixture.service.prepareSubmission(answer: answer)
    let queued = try await fixture.service.submit(prepared, context: origin.executionContext)

    // when
    let completed = try await fixture.finish(queued.id)

    // then
    #expect(completed.state == .needsReview)
    #expect(completed.answer == answer)
    #expect(completed.pullRequestURL == nil)
    #expect(completed.failureReason?.contains("approved baseline") == true)
    #expect(await fixture.publisher.attempts == 0)
  }
}
