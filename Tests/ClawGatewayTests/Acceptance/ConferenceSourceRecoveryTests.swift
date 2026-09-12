import ClawCore
import ClawTestSupport
import Testing

@Suite struct ConferenceSourceRecoveryTests {
  @Test(arguments: [
    (ConferenceSourceError.gitFailed, ConferenceSubmissionState.completed),
    (.baselineMismatch, .needsReview),
  ]) func sourceFailuresRetryOnlyWhenTransient(
    failure: ConferenceSourceError,
    expectedState: ConferenceSubmissionState
  ) async throws {
    // given
    let failed = AsyncGate()
    let notified = AsyncGate()
    let fixture = try ConferenceWorkflowFixture(
      prepareSource: { item in
        if !failed.isOpen {
          failed.open()
          throw failure
        }
        return "/conference/source/\(item.id)"
      },
      notifyOutbox: { notified.open() }
    )
    let answer = "Restore the accessibility labels."
    let origin = try fixture.origin(answer: answer)
    let prepared = try await fixture.service.prepareSubmission(answer: answer)
    let queued = try await fixture.service.submit(prepared, context: origin.executionContext)

    // when
    let runner = Task { try await fixture.service.run() }
    let finished = await notified.waitUntilOpen()
    runner.cancel()
    try await runner.value

    // then
    try #require(finished)
    let submission = try #require(try fixture.store.submission(id: queued.id))
    #expect(submission.state == expectedState)
  }
}
