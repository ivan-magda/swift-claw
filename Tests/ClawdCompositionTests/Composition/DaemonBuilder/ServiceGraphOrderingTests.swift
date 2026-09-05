import ClawAgent
import ClawGateway
import Logging
import ServiceLifecycle
import Testing

@testable import clawd

@Suite struct ServiceGraphOrderingTests {
  @Test func laneAdmissionServiceIsRegisteredLast() {
    // given — the production ordering helper the composition root uses to build its service array.
    let laneAdmission = LaneAdmissionShutdownService(
      lanes: SessionLaneRegistry(),
      outcome: LaneShutdownOutcome(),
      drainTimeout: .seconds(30),
      logger: Logger(label: "test", factory: { _ in SwiftLogNoOpLogHandler() })
    )
    let base: [any Service] = [InertService(), InertService()]

    // when
    let ordered = DaemonBuilder.servicesWithLaneAdmissionLast(
      base: base,
      laneAdmission: laneAdmission
    )

    // then — the lane service tails the array (so ServiceLifecycle shuts it down first), and the
    // base services keep their positions ahead of it.
    #expect(ordered.count == 3)
    #expect(ordered.last is LaneAdmissionShutdownService)
    #expect(ordered.prefix(2).allSatisfy { $0 is InertService })
  }
}

private struct InertService: Service {
  func run() async throws {}
}
