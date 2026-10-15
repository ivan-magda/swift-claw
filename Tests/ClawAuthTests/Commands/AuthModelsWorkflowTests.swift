import ClawCore
import ClawSecrets
import Foundation
import Testing

@testable import ClawAuth

@Suite
struct AuthModelsWorkflowTests {
  /// Listing is a read that reaches the vendor once with the stored token. It takes no lock and
  /// saves nothing, which is what lets an owner run it against a live daemon.
  @Test
  func modelsSpendsTheStoredTokenOnOneFetchAndChangesNothing() async throws {
    try await withAuthWorld("auth-models-read") { world in
      // given
      try world.seedPriorLogin()
      let workflow = world.modelsWorkflow()

      // when
      let result = await workflow.models()

      // then
      #expect(result.exit == .success)
      #expect(world.log.recorded == [.credentialStoreOpened, .credentialLoaded, .catalogFetched])
      let authorization = try #require(world.seenCatalogAuthorization)
      #expect(authorization.redactionValues.contains(AuthFixture.priorCredential.accessToken))
      #expect(try world.loadStoredCredential() == AuthFixture.priorCredential)
    }
  }

  @Test
  func modelsPrintsPasteableReferencesAndMarksOnlyTheConfiguredOne() async throws {
    try await withAuthWorld("auth-models-listing") { world in
      // given
      try world.seedPriorLogin()
      let configured = try #require(AuthFixture.catalog.last)
      let other = try #require(AuthFixture.catalog.first)
      world.configuredModel = ChatGPTProviderMetadata.modelPrefix + configured.slug
      let workflow = world.modelsWorkflow()

      // when
      let result = await workflow.models()

      // then
      let lines = result.events.map(\.text)
      let configuredLine = try #require(
        lines.first { line in
          line.hasSuffix(configured.slug + " (configured)")
        }
      )
      #expect(configuredLine.contains(ChatGPTProviderMetadata.modelPrefix + configured.slug))
      let otherLine = try #require(
        lines.first { line in
          line.hasSuffix(ChatGPTProviderMetadata.modelPrefix + other.slug)
        }
      )
      #expect(otherLine.contains("configured") == false)
    }
  }

  @Test
  func modelsListsEachModelsReasoningLevelsBelowItAndMarksTheDefault() async throws {
    try await withAuthWorld("auth-models-reasoning") { world in
      // given
      try world.seedPriorLogin()
      let reasoning = ChatGPTCatalogModel(
        slug: "gpt-5.4",
        priority: 1,
        reasoningLevels: ["low", "medium", "high"],
        defaultReasoningLevel: "medium"
      )
      let plain = ChatGPTCatalogModel(slug: "gpt-5.4-mini", priority: 2)
      world.catalogOutcome = .models([reasoning, plain])
      let workflow = world.modelsWorkflow()

      // when
      let result = await workflow.models()

      // then
      let lines = result.events.map(\.text)
      let reasoningRow = try #require(
        lines.firstIndex { line in
          line.hasSuffix(ChatGPTProviderMetadata.modelPrefix + reasoning.slug)
        }
      )
      let plainRow = try #require(
        lines.firstIndex { line in
          line.hasSuffix(ChatGPTProviderMetadata.modelPrefix + plain.slug)
        }
      )
      let levelsLine = try #require(lines.dropFirst(reasoningRow + 1).first)
      #expect(levelsLine.contains("low, medium (default), high"))
      #expect(plainRow == reasoningRow + 2)
      let levelLines = lines.filter { line in
        line.contains("reasoning effort")
      }
      #expect(levelLines.count == 1)
    }
  }

  /// Renewing an expired token is the daemon's job alone. The command must stop before the vendor
  /// rather than spend a token it knows is dead or rotate one behind the daemon's back.
  @Test
  func anExpiredTokenFailsWithoutContactingTheProvider() async throws {
    try await withAuthWorld("auth-models-expired") { world in
      // given
      _ = try RuntimeSecretPreparer.prepare(stateRoot: world.root, environment: world.environment)
      try EncryptedLLMCredentialStore(stateRoot: world.root).save(
        StoredOAuthCredential(
          profileID: AuthFixture.priorProfileID,
          accessToken: "expired-access-token",
          refreshToken: "expired-refresh-token",
          expiresAt: AuthFixture.now.addingTimeInterval(-60)
        ),
        providerID: .openAIChatGPT
      )
      let workflow = world.modelsWorkflow()

      // when
      let result = await workflow.models()

      // then
      #expect(result.exit == .commandFailure)
      #expect(world.log.recorded == [.credentialStoreOpened, .credentialLoaded])
      #expect(result.transcript.contains("expired"))
    }
  }

  @Test
  func aLoggedOutStateRootFailsAndPointsAtLogin() async throws {
    try await withAuthWorld("auth-models-logged-out") { world in
      // given — nothing has ever been stored here
      let workflow = world.modelsWorkflow()

      // when
      let result = await workflow.models()

      // then
      #expect(result.exit == .commandFailure)
      #expect(world.log.recorded.contains(.catalogFetched) == false)
      #expect(result.transcript.contains("clawd auth login"))
    }
  }

  @Test
  func anUnreadableCatalogFailsWithTheVendorsReason() async throws {
    try await withAuthWorld("auth-models-catalog-failure") { world in
      // given
      try world.seedPriorLogin()
      let detail = "status 401: token revoked"
      world.catalogOutcome = .failure(.unavailable(detail: detail))
      let workflow = world.modelsWorkflow()

      // when
      let result = await workflow.models()

      // then
      #expect(result.exit == .commandFailure)
      #expect(result.transcript.contains(detail))
    }
  }
}
