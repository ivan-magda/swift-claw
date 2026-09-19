import ClawCore
import ClawGateway
import ClawTestSupport
import Foundation
import Testing

@testable import clawd

@Suite
struct ApprovalLifecycleCompositionTests {
  @Test
  func releasingTheDaemonReleasesTheApprovalGraphsTransport() async throws {
    // given
    let config = try CompositionAcceptance.chatGPTConfig()
    defer { try? FileManager.default.removeItem(at: config.stateRoot) }
    var http: ScriptedHTTPExecutor? = ScriptedHTTPExecutor([])
    let transportIsAlive = { [weak http] in
      http != nil
    }
    var bundle: DaemonRuntimeBundle? = try await Self.makeBundle(
      http: #require(http),
      config: config
    )
    http = nil

    // when
    try #require(bundle != nil)
    withExtendedLifetime(bundle) {
      #expect(transportIsAlive())
    }
    bundle = nil

    // then
    #expect(!transportIsAlive())
  }
}

// MARK: - Composition

private extension ApprovalLifecycleCompositionTests {
  static func makeBundle(
    http: ScriptedHTTPExecutor,
    config: AppConfig
  ) async throws -> DaemonRuntimeBundle {
    let builder = try CompositionAcceptance.makeBuilder(http: http, config: config)
    return try await builder.build(
      rosterStack: builder.makeRosterStack(http: http),
      cooldown: PrimaryRouteCooldown(
        longSeconds: config.llm.primaryCooldownSeconds,
        clock: ContinuousClock()
      )
    )
  }
}
