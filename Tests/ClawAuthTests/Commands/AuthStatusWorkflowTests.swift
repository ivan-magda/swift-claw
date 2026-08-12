import ClawCore
import ClawSecrets
import ClawTestSupport
import Foundation
import Testing

@testable import ClawAuth

@Suite struct AuthStatusWorkflowTests {
  /// Status is a read. It takes no lock and refreshes nothing — which is what lets an owner run it
  /// against a live daemon without fighting it for the state root.
  @Test func statusTakesNoLockAndContactsNobody() async throws {
    try await withAuthWorld("auth-status-quiet") { world in
      // given
      try world.seedPriorLogin()
      let workflow = world.statusWorkflow()

      // when
      let result = workflow.status()

      // then
      #expect(result.exit == .success)
      #expect(world.log.recorded == [.credentialStoreOpened, .credentialLoaded])
      // The pairing that proves the log can record those effects at all: login, built from this same
      // world and writing to this same log, does take the lock and does reach the vendor.
      _ = await world.loginWorkflow().login()
      #expect(world.log.recorded.contains(.lockAcquired))
      #expect(world.log.recorded.contains(.deviceAuthorizationStarted))
    }
  }

  @Test func statusReportsPresenceExpiryAndFreshnessWithoutAnyTokenText() async throws {
    try await withAuthWorld("auth-status-present") { world in
      // given
      try world.seedPriorLogin()
      let workflow = world.statusWorkflow()

      // when
      let result = workflow.status()

      // then
      #expect(result.exit == .success)
      #expect(result.transcript.contains(LLMProviderID.openAIChatGPT.rawValue))
      #expect(result.transcript.contains(AuthFixture.priorCredential.accessToken) == false)
      #expect(result.transcript.contains(AuthFixture.priorCredential.refreshToken) == false)
      #expect(result.transcript.contains(AuthFixture.priorProfileID.uuidString) == false)
    }
  }

  /// The 120-second skew belongs to one classifier. Status must read through it rather than restate
  /// it, or an owner can be told a token is fresh while the source that will spend it disagrees.
  @Test(arguments: [
    (Duration.seconds(3600), ChatGPTCredentialFreshness.fresh, "fresh"),
    (Duration.seconds(60), ChatGPTCredentialFreshness.expiring, "expiring"),
    (Duration.seconds(-60), ChatGPTCredentialFreshness.expired, "expired"),
  ])
  func statusNamesTheFreshnessClassTheSharedRuleWouldName(
    remaining: Duration,
    expected: ChatGPTCredentialFreshness,
    label: String
  ) async throws {
    try await withAuthWorld("auth-status-freshness") { world in
      // given
      let expiresAt = AuthFixture.now.addingTimeInterval(
        TimeInterval(remaining.components.seconds)
      )
      _ = try RuntimeSecretPreparer.prepare(stateRoot: world.root, environment: world.environment)
      try EncryptedLLMCredentialStore(stateRoot: world.root).save(
        StoredOAuthCredential(
          profileID: AuthFixture.priorProfileID,
          accessToken: "some-access-token",
          refreshToken: "some-refresh-token",
          expiresAt: expiresAt
        ),
        providerID: .openAIChatGPT
      )
      let workflow = world.statusWorkflow()

      // when
      let result = workflow.status()

      // then
      #expect(
        ChatGPTCredentialFreshness.classify(expiresAt: expiresAt, now: AuthFixture.now) == expected
      )
      #expect(result.exit == .success)
      #expect(result.transcript.contains(label))
    }
  }

  @Test func aLoggedOutStatusIsDescriptiveAndSucceeds() async throws {
    try await withAuthWorld("auth-status-logged-out") { world in
      // given — nothing has ever been stored here
      let workflow = world.statusWorkflow()

      // when
      let result = workflow.status()

      // then
      #expect(result.exit == .success)
      #expect(result.transcript.lowercased().contains("logged out"))
    }
  }

  @Test func statusShowsTheConfiguredChatGPTModelWhenTheEnvironmentNamesOne() async throws {
    try await withAuthWorld("auth-status-model") { world in
      // given
      try world.seedPriorLogin()
      world.configuredModel = "openai-chatgpt/gpt-5.4"
      let workflow = world.statusWorkflow()

      // when
      let result = workflow.status()

      // then
      #expect(result.transcript.contains("openai-chatgpt/gpt-5.4"))
    }
  }

  /// A model belonging to the fallback route says nothing about this provider's credential, so
  /// status must not present it as though it did.
  @Test func statusShowsNoModelWhenTheEnvironmentNamesAnotherRoutesModel() async throws {
    try await withAuthWorld("auth-status-other-model") { world in
      // given
      try world.seedPriorLogin()
      world.configuredModel = "gpt-4o"
      let workflow = world.statusWorkflow()

      // when
      let result = workflow.status()

      // then
      #expect(result.transcript.contains("gpt-4o") == false)
    }
  }

  /// An envelope that exists but cannot be opened is not a logged-out state; it is a secret-load
  /// failure, and it must not read as "just log in again".
  @Test func anUnreadableCredentialEnvelopeIsASecretLoadFailure() async throws {
    try await withAuthWorld("auth-status-corrupt") { world in
      // given
      try world.seedPriorLogin()
      try Data("not an envelope".utf8).write(to: world.paths.credentialEnvelope)
      let workflow = world.statusWorkflow()

      // when
      let result = workflow.status()

      // then
      #expect(result.exit == .secretLoadFailure)
    }
  }
}
