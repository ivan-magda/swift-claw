import ClawAgent
import ClawCore
import Testing

@testable import ClawGateway

@Suite struct DaemonRuntimeBundleTests {
  @Test func outcomeExposesNothingUntilARecordLands() async {
    // given
    let outcome = LaneShutdownOutcome()

    // then — nothing recorded yet…
    #expect(await outcome.value() == nil)

    // when
    await outcome.record(.timedOut(activeRunIDs: [4, 8]))

    // then — …and the recorded value is exposed verbatim.
    #expect(await outcome.value() == .timedOut(activeRunIDs: [4, 8]))
  }

  @Test func outcomeExposesADrainedResult() async {
    // given
    let outcome = LaneShutdownOutcome()

    // when
    await outcome.record(.drained)

    // then
    #expect(await outcome.value() == .drained)
  }

  @Test func bundleCarriesTheExactRuntimePieces() {
    // given
    let lanes = SessionLaneRegistry()
    let outcome = LaneShutdownOutcome()
    let source = FakeCredentialSource()
    let daemon = Daemon(services: [], logger: TestLog.silent)

    // when
    let bundle = DaemonRuntimeBundle(
      daemon: daemon,
      lanes: lanes,
      credentialSource: source,
      laneShutdownOutcome: outcome
    )

    // then — the bundle retains the very instances composition wired, not copies.
    #expect(bundle.lanes === lanes)
    #expect(bundle.laneShutdownOutcome === outcome)
    #expect((bundle.credentialSource as? FakeCredentialSource) === source)
    #expect(bundle.daemon.services.isEmpty)
  }
}

private final class FakeCredentialSource: LLMCredentialSource {
  func authorization() async throws -> LLMRequestAuthorization {
    LLMRequestAuthorization(headers: [:], redactionValues: [], generation: .zero)
  }

  func reject(generation: LLMCredentialGeneration, disposition: LLMCredentialRejection) async {}

  func shutdown() async throws {}
}
