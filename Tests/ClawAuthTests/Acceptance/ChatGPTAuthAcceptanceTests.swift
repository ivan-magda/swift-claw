import ClawCore
import ClawGateway
import ClawSecrets
import ClawTestSupport
import Foundation
import Testing

@testable import ClawAuth

/// End-to-end auth acceptance: the production auth workflows over a real state root, real secret
/// sealing, a real encrypted credential store, and a real instance lock — driving the *real* device,
/// OAuth, and catalog clients across **scripted HTTP** and a **manual clock**. Where the per-command
/// workflow suites inject scripted seams, this suite proves the integrated flow reaches the pinned
/// ChatGPT URLs (or provably does not), so a broken transition surfaces as a wire-level assertion.
@Suite struct ChatGPTAuthAcceptanceTests {
  // MARK: - The Whole Login, End to End

  /// Pending-then-grant is collapsed to a first-poll grant here (the scripted transport answers a URL
  /// once); the device suite covers multi-poll pacing. What this proves is the whole integrated walk:
  /// seal → device egress → exchange → save → catalog → the exact qualified assignment.
  @Test func loginWalksTheRealClientsToTheQualifiedAssignment() async throws {
    try await withAuthAcceptanceWorld("acc-auth-login") { world in
      // given
      let http = world.makeHTTP()
      let workflow = world.loginWorkflow(http: http)

      // when
      let result = await workflow.login()

      // then — the exact pinned URLs, in order, were reached by the real clients
      #expect(result.exit == .success)
      #expect(await http.requestedURLs == AcceptanceAuthFixture.orderedURLs)
      // the credential landed under a fresh profile
      let stored = world.storedCredential
      #expect(stored?.profileID == AcceptanceAuthFixture.freshProfileID)
      #expect(stored?.accessToken == AcceptanceAuthFixture.accessToken)
      #expect(stored?.refreshToken == AcceptanceAuthFixture.refreshToken)
      // the encrypted backend is now real on disk
      #expect(FileManager.default.fileExists(atPath: world.paths.key.path))
      #expect(FileManager.default.fileExists(atPath: world.paths.credentialEnvelope.path))
      // and the owner was handed the exact qualified model line
      #expect(world.terminal.transcript.contains("CLAW_LLM_MODEL=openai-chatgpt/gpt-5.4"))
    }
  }

  /// The gate before any egress: a root that cannot produce runtime secrets is one login stops at
  /// before the first wire call. Its pairing is the happy path above, where the same real client did
  /// reach the vendor.
  @Test func missingRuntimeSecretsStopLoginBeforeAnyOAuthRequestOrFile() async throws {
    try await withAuthAcceptanceWorld("acc-auth-no-secrets") { world in
      // given — nothing to seal
      world.environment = [:]
      let http = world.makeHTTP()
      let workflow = world.loginWorkflow(http: http)

      // when
      let result = await workflow.login()

      // then — no wire call, no files
      #expect(result.exit == .secretLoadFailure)
      #expect(await http.requestedURLs.isEmpty)
      #expect(FileManager.default.fileExists(atPath: world.paths.key.path) == false)
      #expect(FileManager.default.fileExists(atPath: world.paths.credentialEnvelope.path) == false)
    }
  }

  /// Exactly one encrypted artifact is a state login must never repair by minting the other; it fails
  /// closed and reaches no vendor.
  @Test func aPartialEncryptedStateFailsClosedBeforeEgress() async throws {
    try await withAuthAcceptanceWorld("acc-auth-partial") { world in
      // given — seal, then remove the envelope: the key alone remains
      _ = try RuntimeSecretPreparer.prepare(stateRoot: world.root, environment: world.environment)
      try FileManager.default.removeItem(at: world.paths.runtimeEnvelope)
      let http = world.makeHTTP()
      let workflow = world.loginWorkflow(http: http)

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .secretLoadFailure)
      #expect(await http.requestedURLs.isEmpty)
      #expect(world.terminal.transcript.contains("clawd secrets seal"))
    }
  }

  /// ChatGPT auth is composed with neither a base URL nor an API key: the environment carries only the
  /// Telegram token that gets sealed, and login still completes over the pinned endpoints.
  @Test func loginNeedsNeitherBaseURLNorAPIKey() async throws {
    try await withAuthAcceptanceWorld("acc-auth-no-key") { world in
      // given — no CLAW_LLM_BASE_URL, no CLAW_LLM_API_KEY in the environment
      #expect(world.environment["CLAW_LLM_BASE_URL"] == nil)
      #expect(world.environment["CLAW_LLM_API_KEY"] == nil)
      let http = world.makeHTTP()
      let workflow = world.loginWorkflow(http: http)

      // when
      let result = await workflow.login()

      // then — every reached URL is a pinned ChatGPT host; none is a configured base URL
      #expect(result.exit == .success)
      let urls = await http.requestedURLs
      #expect(
        urls.allSatisfy {
          $0.hasPrefix("https://auth.openai.com") || $0.hasPrefix("https://chatgpt.com")
        }
      )
    }
  }

  // MARK: - Replacement and Preservation

  @Test func aReloginMintsANewProfileID() async throws {
    try await withAuthAcceptanceWorld("acc-auth-relogin") { world in
      // given
      try world.seedPriorLogin()
      #expect(world.storedCredential?.profileID == AcceptanceAuthFixture.priorProfileID)
      let http = world.makeHTTP()
      let workflow = world.loginWorkflow(http: http)

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .success)
      #expect(world.storedCredential?.profileID == AcceptanceAuthFixture.freshProfileID)
    }
  }

  @Test func aFailedExchangePreservesThePriorCredential() async throws {
    try await withAuthAcceptanceWorld("acc-auth-exchange-fails") { world in
      // given — the token endpoint rejects the grant
      try world.seedPriorLogin()
      world.responses[ChatGPTProviderMetadata.tokenURL] = AcceptanceAuthFixture.result(
        400,
        #"{"error":"invalid_grant"}"#
      )
      let http = world.makeHTTP()
      let workflow = world.loginWorkflow(http: http)

      // when
      let result = await workflow.login()

      // then — the prior credential is exactly as it was, and the catalog was never reached
      #expect(result.exit == .commandFailure)
      #expect(world.storedCredential == AcceptanceAuthFixture.priorCredential)
      #expect(await http.requestedURLs.contains(ChatGPTProviderMetadata.modelsURL) == false)
    }
  }

  // MARK: - The Catalog Is Not The Login

  @Test func aCatalogFailureKeepsTheLoginAndPrintsTheManualForm() async throws {
    try await withAuthAcceptanceWorld("acc-auth-catalog-fails") { world in
      // given — the catalog endpoint 500s after the credential has been stored
      world.responses[ChatGPTProviderMetadata.modelsURL] = AcceptanceAuthFixture.result(
        500,
        #"{"error":"server_error"}"#
      )
      let http = world.makeHTTP()
      let workflow = world.loginWorkflow(http: http)

      // when
      let result = await workflow.login()

      // then — login succeeded and the manual form is offered
      #expect(result.exit == .success)
      #expect(world.storedCredential?.profileID == AcceptanceAuthFixture.freshProfileID)
      #expect(world.terminal.transcript.contains("CLAW_LLM_MODEL=openai-chatgpt/<model>"))
    }
  }

  // MARK: - The Lock

  @Test func aHeldLockStopsLoginBeforeAnyEgress() async throws {
    try await withAuthAcceptanceWorld("acc-auth-locked") { world in
      // given
      world.lockFailure = .held
      let http = world.makeHTTP()
      let workflow = world.loginWorkflow(http: http)

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .commandFailure)
      #expect(await http.requestedURLs.isEmpty)
      #expect(world.terminal.transcript.lowercased().contains("stop"))
    }
  }

  /// Status reads through a held daemon lock: no lock acquisition and no token bytes. That it also
  /// makes no wire call is no longer something a test can catch it at — `AuthStatusWorkflow` is
  /// handed no transport to reach for — so what is asserted here is the half that stayed behavioral.
  @Test func statusReadsThroughAHeldLockWithoutNetwork() async throws {
    try await withAuthAcceptanceWorld("acc-auth-status") { world in
      // given — a daemon holds the instance lock
      try world.seedPriorLogin()
      let daemon = try InstanceLock(path: world.paths.instanceLock.path)
      defer { daemon.release() }
      world.mutationLock = RealInstanceLocking(
        path: world.paths.instanceLock.path,
        log: world.log
      )
      let workflow = world.statusWorkflow()

      // when
      let result = workflow.status()

      // then — read-only: no lock taken, and real status output that names the provider and the
      // seeded credential — so the token-absence check below is over a real transcript, not a
      // vacuously empty one.
      #expect(result.exit == .success)
      #expect(world.log.recorded.contains(.lockAcquired) == false)
      #expect(result.transcript.contains("provider: openai-chatgpt"))
      #expect(result.transcript.contains("credential: present"))
      #expect(
        result.transcript.contains(AcceptanceAuthFixture.priorCredential.accessToken) == false
      )
    }
  }
}
