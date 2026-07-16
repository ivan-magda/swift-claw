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
}
