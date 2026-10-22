import ClawCore
import ClawSecrets
import ClawSubprocess
import ClawTestSupport
import Foundation
import Testing

@testable import ClawAuth

/// End-to-end auth acceptance: the production auth workflows over a real state root, real secret
/// sealing, a real encrypted credential store, and a real instance lock — driving the *real* device,
/// OAuth, and catalog clients across **scripted HTTP** and a **manual clock**. Where the per-command
/// workflow suites inject scripted seams, this suite proves the integrated flow reaches the pinned
/// ChatGPT URLs (or provably does not), so a broken transition surfaces as a wire-level assertion.
@Suite
struct ChatGPTAuthAcceptanceTests {
  // MARK: - The Whole Login, End to End

  /// Pending-then-grant is collapsed to a first-poll grant here (the scripted transport answers a URL
  /// once); the device suite covers multi-poll pacing. What this proves is the whole integrated walk:
  /// seal → device egress → exchange → save → catalog → the exact qualified assignment.
  @Test
  func loginWalksTheRealClientsToTheQualifiedAssignment() async throws {
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

  // MARK: - Preservation

  @Test
  func aFailedExchangePreservesThePriorCredential() async throws {
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

  @Test
  func aCatalogFailureKeepsTheLoginAndPrintsTheManualForm() async throws {
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

  /// Status reads through a held daemon lock: no lock acquisition and no token bytes. That it also
  /// makes no wire call is no longer something a test can catch it at — `AuthStatusWorkflow` is
  /// handed no transport to reach for — so what is asserted here is the half that stayed behavioral.
  @Test
  func statusReadsThroughAHeldLockWithoutNetwork() async throws {
    try await withAuthAcceptanceWorld("acc-auth-status") { world in
      // given — a daemon holds the instance lock
      try world.seedPriorLogin()
      let daemon = try InstanceLock(path: world.paths.instanceLock.path)
      defer { daemon.release() }
      world.mutationLock = RealInstanceLocking(path: world.paths.instanceLock.path, log: world.log)
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
