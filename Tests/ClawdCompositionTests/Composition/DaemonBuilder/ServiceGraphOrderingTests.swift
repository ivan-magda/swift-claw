import ClawTestSupport
import Testing

@testable import ClawGateway
@testable import clawd

@Suite
struct ServiceGraphOrderingTests {
  @Test
  func laneAdmissionServiceIsRegisteredLast() async throws {
    // given — the production bundle owns journal shutdown alongside producer services.
    let fixture = try JournalCompositionFixture(enabled: true)
    defer { fixture.removeFiles() }
    // when — build performs the worker registration and retains fallback ownership.
    let bundle = try await fixture.bundle(provider: SequenceProvider([]))
    let journal = try #require(bundle.journal)
    let ordered = bundle.daemon.services

    // then — the lane service tails the array (so ServiceLifecycle shuts it down first), and the
    // worker precedes producers, so shutdown joins them before stopping journal inference.
    #expect((ordered.first as? JournalWorker) === journal)
    #expect(ordered.last is LaneAdmissionShutdownService)
    let workerIndex = try #require(ordered.firstIndex { $0 is JournalWorker })
    let producerIndexes = ordered.indices.filter { index in
      ordered[index] is TelegramPollerService || ordered[index] is SchedulerService
        || ordered[index] is CoderService
    }
    #expect(producerIndexes.isEmpty == false)
    #expect(producerIndexes.allSatisfy { $0 > workerIndex })
    await journal.shutdown()
    try await bundle.coder?.shutdown()
  }
}
