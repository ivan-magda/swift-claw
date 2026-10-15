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
      let plain = ChatGPTCatalogModel(
        slug: "gpt-5.4-mini",
        priority: 2,
        reasoningLevels: [],
        defaultReasoningLevel: nil
      )
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

  /// The configured level is marked beside the model it applies to, and only there, so the owner
  /// can check it against the levels that model lists.
  @Test(arguments: [
    (configured: LLMReasoningEffort.high, marked: "low, medium (default), high (configured)"),
    (configured: .medium, marked: "low, medium (default, configured), high"),
  ])
  func modelsMarksTheConfiguredLevelOnTheConfiguredModelOnly(
    configured: LLMReasoningEffort,
    marked: String
  ) async throws {
    try await withAuthWorld("auth-models-configured-level") { world in
      // given
      try world.seedPriorLogin()
      let levels = ["low", "medium", "high"]
      let selected = ChatGPTCatalogModel(
        slug: "gpt-5.4",
        priority: 1,
        reasoningLevels: levels,
        defaultReasoningLevel: "medium"
      )
      let other = ChatGPTCatalogModel(
        slug: "gpt-5.4-mini",
        priority: 2,
        reasoningLevels: levels,
        defaultReasoningLevel: "medium"
      )
      world.catalogOutcome = .models([selected, other])
      world.configuredModel = ChatGPTProviderMetadata.modelPrefix + selected.slug
      world.configuredReasoningEffort = configured
      let workflow = world.modelsWorkflow()

      // when
      let result = await workflow.models()

      // then
      let lines = result.events.map(\.text)
      let selectedRow = try #require(
        lines.firstIndex { line in
          line.hasSuffix(selected.slug + " (configured)")
        }
      )
      let otherRow = try #require(
        lines.firstIndex { line in
          line.hasSuffix(ChatGPTProviderMetadata.modelPrefix + other.slug)
        }
      )
      let selectedLevels = try #require(lines.dropFirst(selectedRow + 1).first)
      let otherLevels = try #require(lines.dropFirst(otherRow + 1).first)
      #expect(selectedLevels.hasSuffix(marked))
      #expect(otherLevels.contains("configured") == false)
      #expect(
        lines.contains { line in
          line.contains(AppConfig.EnvKey.llmReasoningEffort)
        } == false
      )
    }
  }

  /// A level the configured model does not list may fail every message on the wire, so the listing
  /// names it, in the word the owner typed, rather than leaving the owner to spot the gap.
  @Test
  func modelsWarnsWhenTheConfiguredModelDoesNotListTheConfiguredLevel() async throws {
    try await withAuthWorld("auth-models-unlisted-level") { world in
      // given — `none` is spelled differently from its Swift case, so the warning must use the word
      let selected = ChatGPTCatalogModel(
        slug: "gpt-5.4",
        priority: 1,
        reasoningLevels: ["low", "medium", "high"],
        defaultReasoningLevel: "medium"
      )
      try world.seedPriorLogin()
      world.catalogOutcome = .models([selected])
      world.configuredModel = ChatGPTProviderMetadata.modelPrefix + selected.slug
      world.configuredReasoningEffort = .disabled
      let workflow = world.modelsWorkflow()

      // when
      let result = await workflow.models()

      // then
      let lines = result.events.map(\.text)
      let selectedRow = try #require(
        lines.firstIndex { line in
          line.hasSuffix(selected.slug + " (configured)")
        }
      )
      let warning = try #require(lines.dropFirst(selectedRow + 2).first)
      let setting = "\(AppConfig.EnvKey.llmReasoningEffort)=\(LLMReasoningEffort.disabled.rawValue)"
      #expect(warning.contains(setting))
    }
  }

  /// A model that lists no levels gives nothing to check the configured one against.
  @Test
  func aConfiguredModelThatListsNoLevelsDrawsNoWarning() async throws {
    try await withAuthWorld("auth-models-no-levels") { world in
      // given
      let selected = ChatGPTCatalogModel(
        slug: "gpt-5.4-mini",
        priority: 1,
        reasoningLevels: [],
        defaultReasoningLevel: nil
      )
      try world.seedPriorLogin()
      world.catalogOutcome = .models([selected])
      world.configuredModel = ChatGPTProviderMetadata.modelPrefix + selected.slug
      world.configuredReasoningEffort = .high
      let workflow = world.modelsWorkflow()

      // when
      let result = await workflow.models()

      // then
      let lines = result.events.map(\.text)
      #expect(
        lines.contains { line in
          line.hasSuffix(selected.slug + " (configured)")
        }
      )
      #expect(
        lines.contains { line in
          line.contains(AppConfig.EnvKey.llmReasoningEffort)
        } == false
      )
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
