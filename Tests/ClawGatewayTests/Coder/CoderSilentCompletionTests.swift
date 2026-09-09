import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawGateway

extension CoderServiceTests {
  @Test func disabledCompletionNoticesPersistResultWithoutGenericOutboxMessage() async throws {
    let fixture = try CoderServiceFixture()
    defer { fixture.cleanup() }
    let service = CoderService(
      store: fixture.store,
      backend: fixture.backend,
      preparer: fixture.preparer,
      inspector: fixture.inspector,
      config: CoderConfig(
        enabled: true,
        maxConcurrentJobs: 1,
        jobTimeoutSeconds: 600,
        executable: CoderConfig.Defaults.executable,
        profile: nil,
        configHome: nil
      ),
      jobRoot: fixture.root.path,
      executionPolicyID: CoderServiceFixture.executionPolicyID,
      completionNoticesEnabled: false,
      redact: { $0 },
      notifyOutbox: {
        Issue.record("Silent Coder completion must not signal the generic outbox")
      }
    )
    try await service.start()
    let job = try await service.submit(fixture.prepared, context: fixture.ownerContext)
    await fixture.backend.started.wait()

    fixture.backend.releaseAll()

    let completed = try await pollUntil {
      guard let current = try fixture.store.job(id: job.id), current.state.isTerminal else {
        return nil
      }
      return current
    }
    #expect(completed?.result?.state == .succeeded)
    #expect(try fixture.reports().isEmpty)

    try await service.shutdown()
  }
}
