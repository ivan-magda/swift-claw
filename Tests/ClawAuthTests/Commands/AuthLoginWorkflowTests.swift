import ClawCore
import ClawSecrets
import ClawTestSupport
import Foundation
import Testing

@testable import ClawAuth

@Suite struct AuthLoginWorkflowTests {
  /// The master ordering assertion. Each edge the spec pins is an adjacency in this one list, so a
  /// mutation that moves any step — the lock after the seal, the seal after the first request, the
  /// save before the exchange — changes it.
  @Test func loginRunsTheWholeSequenceInThePinnedOrder() async throws {
    try await withAuthWorld("auth-login-order") { world in
      // given
      let workflow = world.loginWorkflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .success)
      #expect(
        world.log.recorded == [
          .lockAcquired,
          .runtimeSecretsPrepared,
          .deviceAuthorizationStarted,
          .tokenExchanged,
          .credentialStoreOpened,
          .credentialSaved,
          .catalogFetched,
          .lockReleased,
        ]
      )
    }
  }

  @Test func loginPrintsTheUserCodeBeforeItStartsWaitingForApproval() async throws {
    try await withAuthWorld("auth-login-prompt") { world in
      // given
      let workflow = world.loginWorkflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .success)
      #expect(world.terminal.transcript.contains(AuthFixture.device.userCode))
      #expect(world.terminal.transcript.contains(ChatGPTProviderMetadata.verificationURL))
    }
  }

  /// The contract every renderer leans on: nothing left in `events` has been shown. Login streams as
  /// it goes, so by the time it returns it has nothing to hand over — which is what lets Task 18
  /// print `events` for all three commands without printing login's transcript a second time.
  @Test func loginReturnsNoEventsBecauseItHasAlreadyPresentedThemAll() async throws {
    try await withAuthWorld("auth-login-streamed") { world in
      // given
      let workflow = world.loginWorkflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .success)
      #expect(result.events.isEmpty)
      // The pairing: empty because the owner has already seen every line, not because login went
      // quiet. The terminal holds the whole ordered transcript.
      #expect(world.terminal.written.isEmpty == false)
      #expect(world.terminal.transcript.contains(AuthFixture.device.userCode))
      #expect(world.terminal.transcript.contains("Logged in to"))
      #expect(world.terminal.transcript.contains("CLAW_LLM_MODEL=openai-chatgpt/gpt-5.4"))
    }
  }

  /// The device-auth ID is a bearer of the pending authorization. It has no business in a transcript,
  /// and the fixture's is distinctive enough that any leak — through a mirror, an error, or an
  /// interpolation — shows up here.
  @Test func loginNeverPrintsTheDeviceAuthID() async throws {
    try await withAuthWorld("auth-login-redaction") { world in
      // given
      let workflow = world.loginWorkflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .success)
      #expect(world.terminal.transcript.contains(AuthFixture.deviceAuthID) == false)
      #expect(world.terminal.transcript.contains(AuthFixture.accessToken) == false)
      #expect(world.terminal.transcript.contains(AuthFixture.refreshToken) == false)
      // The pairing: the transcript really did carry the login's printable half.
      #expect(world.terminal.transcript.contains(AuthFixture.device.userCode))
    }
  }

  @Test func loginStoresTheExchangedPairUnderAFreshProfileID() async throws {
    try await withAuthWorld("auth-login-store") { world in
      // given
      let workflow = world.loginWorkflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .success)
      let stored = world.storedCredential
      #expect(stored?.profileID == AuthFixture.freshProfileID)
      #expect(stored?.accessToken == AuthFixture.accessToken)
      #expect(stored?.refreshToken == AuthFixture.refreshToken)
      #expect(stored?.expiresAt == AuthFixture.expiry)
    }
  }

  @Test func aSuccessfulReloginReplacesThePriorRecordWithANewProfile() async throws {
    try await withAuthWorld("auth-login-replace") { world in
      // given
      try world.seedPriorLogin()
      #expect(world.storedCredential?.profileID == AuthFixture.priorProfileID)
      let workflow = world.loginWorkflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .success)
      #expect(world.storedCredential?.profileID == AuthFixture.freshProfileID)
      #expect(world.storedCredential?.accessToken == AuthFixture.accessToken)
    }
  }

  // MARK: - The Lock Comes First

  @Test func aHeldLockStopsLoginBeforeItTouchesAnythingAtAll() async throws {
    try await withAuthWorld("auth-login-locked") { world in
      // given
      world.lockFailure = .held
      let workflow = world.loginWorkflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .commandFailure)
      // Nothing was sealed, nothing was asked of the vendor, nothing was written.
      #expect(world.log.recorded.isEmpty)
      #expect(FileManager.default.fileExists(atPath: world.paths.key.path) == false)
      #expect(FileManager.default.fileExists(atPath: world.paths.runtimeEnvelope.path) == false)
      #expect(
        FileManager.default.fileExists(atPath: world.paths.credentialEnvelope.path) == false
      )
    }
  }

  @Test func aHeldLockTellsTheOwnerToStopTheDaemon() async throws {
    try await withAuthWorld("auth-login-locked-message") { world in
      // given
      world.lockFailure = .held
      let workflow = world.loginWorkflow()

      // when
      let result = await workflow.login()

      // then
      #expect(world.terminal.transcript.lowercased().contains("stop"))
      #expect(world.terminal.transcript.lowercased().contains("running"))
      #expect(world.terminal.written.allSatisfy { $0.destination == .standardError })
      // A refusal is presented like everything else login says, so it too has nothing left over.
      #expect(result.events.isEmpty)
    }
  }

  // MARK: - The Transition

  @Test func loginSealsTheEnvironmentSecretsBeforeItWritesACredential() async throws {
    try await withAuthWorld("auth-login-seal") { world in
      // given — an environment-backed root: neither encrypted artifact exists yet
      #expect(FileManager.default.fileExists(atPath: world.paths.key.path) == false)
      let workflow = world.loginWorkflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .success)
      #expect(FileManager.default.fileExists(atPath: world.paths.key.path))
      #expect(FileManager.default.fileExists(atPath: world.paths.runtimeEnvelope.path))
      #expect(FileManager.default.fileExists(atPath: world.paths.credentialEnvelope.path))
      let sealIndex = try #require(world.log.recorded.firstIndex(of: .runtimeSecretsPrepared))
      let saveIndex = try #require(world.log.recorded.firstIndex(of: .credentialSaved))
      #expect(sealIndex < saveIndex)
    }
  }

  /// The gate that must hold before any egress: a root that cannot produce runtime secrets is a root
  /// login stops at, before it has told the vendor a device exists.
  @Test func missingRuntimeSecretsFailLoginBeforeItContactsTheVendor() async throws {
    try await withAuthWorld("auth-login-no-secrets") { world in
      // given — no Telegram token, so there is nothing to seal
      world.environment = [:]
      let workflow = world.loginWorkflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .secretLoadFailure)
      #expect(world.log.recorded == [.lockAcquired, .lockReleased])
      #expect(FileManager.default.fileExists(atPath: world.paths.key.path) == false)
      #expect(FileManager.default.fileExists(atPath: world.paths.runtimeEnvelope.path) == false)
      #expect(
        FileManager.default.fileExists(atPath: world.paths.credentialEnvelope.path) == false
      )
    }
  }

  /// Exactly one encrypted artifact is the state login must never repair by minting the other. It
  /// fails closed with the daemon's own repair guidance, and creates nothing.
  @Test func aPartialEncryptedStateFailsClosedWithRepairGuidance() async throws {
    try await withAuthWorld("auth-login-partial") { world in
      // given — seal, then remove the envelope: the key alone remains
      _ = try RuntimeSecretPreparer.prepare(stateRoot: world.root, environment: world.environment)
      try FileManager.default.removeItem(at: world.paths.runtimeEnvelope)
      #expect(FileManager.default.fileExists(atPath: world.paths.key.path))
      let workflow = world.loginWorkflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .secretLoadFailure)
      #expect(world.terminal.transcript.contains("clawd secrets seal"))
      #expect(world.log.recorded == [.lockAcquired, .lockReleased])
      // The half that was already there is untouched, and no credential joined it.
      #expect(FileManager.default.fileExists(atPath: world.paths.key.path))
      #expect(FileManager.default.fileExists(atPath: world.paths.runtimeEnvelope.path) == false)
      #expect(
        FileManager.default.fileExists(atPath: world.paths.credentialEnvelope.path) == false
      )
    }
  }

  // MARK: - Nothing Is Saved Before The Exchange Succeeds

  @Test func aFailedExchangePreservesThePriorCredential() async throws {
    try await withAuthWorld("auth-login-exchange-fails") { world in
      // given
      try world.seedPriorLogin()
      world.exchangeOutcome = .failure {
        ChatGPTOAuthFailure.grantRejected(detail: "the code was already spent")
      }
      let workflow = world.loginWorkflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .commandFailure)
      #expect(world.storedCredential == AuthFixture.priorCredential)
      #expect(world.log.recorded.contains(.credentialSaved) == false)
    }
  }

  @Test func aCancelledApprovalPreservesThePriorCredential() async throws {
    try await withAuthWorld("auth-login-cancelled") { world in
      // given
      try world.seedPriorLogin()
      world.deviceOutcome = .failure { CancellationError() }
      let workflow = world.loginWorkflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .cancelled)
      #expect(world.storedCredential == AuthFixture.priorCredential)
      #expect(world.log.recorded.contains(.credentialSaved) == false)
    }
  }

  /// A pair with no refresh token cannot be stored into a refresh loop, so it is refused rather than
  /// saved — and refusing it must cost the owner nothing they already had.
  @Test func anExchangeWithoutARefreshTokenPreservesThePriorCredential() async throws {
    try await withAuthWorld("auth-login-no-refresh") { world in
      // given
      try world.seedPriorLogin()
      world.exchangeOutcome = .pair(
        ChatGPTTokenPair(
          accessToken: AuthFixture.accessToken,
          refreshToken: nil,
          expiresAt: AuthFixture.expiry
        )
      )
      let workflow = world.loginWorkflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .commandFailure)
      #expect(world.storedCredential == AuthFixture.priorCredential)
    }
  }

  @Test func aFailedDeviceAuthorizationNeverReachesTheExchange() async throws {
    try await withAuthWorld("auth-login-device-fails") { world in
      // given
      world.deviceOutcome = .failure { ChatGPTOAuthFailure.deadlineExceeded }
      let workflow = world.loginWorkflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .commandFailure)
      #expect(world.log.recorded.contains(.tokenExchanged) == false)
      #expect(world.log.recorded.contains(.credentialSaved) == false)
    }
  }

  // MARK: - Model Selection

  @Test func aNonInteractiveLoginTakesTheFirstReturnedModelAndExplainsIt() async throws {
    try await withAuthWorld("auth-login-default-model") { world in
      // given
      world.terminal = RecordingTerminal(isInteractive: false)
      let workflow = world.loginWorkflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .success)
      #expect(world.terminal.transcript.contains("CLAW_LLM_MODEL=openai-chatgpt/gpt-5.4"))
    }
  }

  @Test func aConfiguredModelTheCatalogStillOffersIsTheDefault() async throws {
    try await withAuthWorld("auth-login-configured-model") { world in
      // given
      world.configuredModel = "openai-chatgpt/gpt-5.4-mini"
      let workflow = world.loginWorkflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .success)
      #expect(world.terminal.transcript.contains("CLAW_LLM_MODEL=openai-chatgpt/gpt-5.4-mini"))
    }
  }

  @Test func aTerminalOwnerPicksAModelByNumber() async throws {
    try await withAuthWorld("auth-login-picked-model") { world in
      // given
      world.terminal = RecordingTerminal(isInteractive: true, lines: ["2"])
      let workflow = world.loginWorkflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .success)
      #expect(world.terminal.transcript.contains("CLAW_LLM_MODEL=openai-chatgpt/gpt-5.4-mini"))
    }
  }

  @Test func anOutOfRangeAnswerIsAskedAgainRatherThanAccepted() async throws {
    try await withAuthWorld("auth-login-reask") { world in
      // given
      world.terminal = RecordingTerminal(isInteractive: true, lines: ["99", "1"])
      let workflow = world.loginWorkflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .success)
      #expect(world.terminal.transcript.contains("CLAW_LLM_MODEL=openai-chatgpt/gpt-5.4"))
    }
  }

  /// A finite script that never answers: the loop must give up on its own bound and take the
  /// default, because a login that kept asking would wedge a run rather than fail it.
  @Test func anOwnerWhoNeverAnswersGetsTheDefaultRatherThanAnEndlessPrompt() async throws {
    try await withAuthWorld("auth-login-no-answer") { world in
      // given
      world.terminal = RecordingTerminal(isInteractive: true, lines: ["x", "y", "z", "w", "v"])
      let workflow = world.loginWorkflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .success)
      #expect(world.terminal.transcript.contains("CLAW_LLM_MODEL=openai-chatgpt/gpt-5.4"))
    }
  }

  // MARK: - The Catalog Is Not The Login

  @Test func aCatalogFailureKeepsTheLoginAndPrintsTheManualForm() async throws {
    try await withAuthWorld("auth-login-catalog-fails") { world in
      // given
      world.catalogOutcome = .failure(.unavailable(detail: "the model list was not JSON"))
      let workflow = world.loginWorkflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .success)
      #expect(world.storedCredential?.profileID == AuthFixture.freshProfileID)
      #expect(world.terminal.transcript.contains("CLAW_LLM_MODEL=openai-chatgpt/<model>"))
    }
  }

  @Test func anEmptyCatalogKeepsTheLoginAndPrintsTheManualForm() async throws {
    try await withAuthWorld("auth-login-catalog-empty") { world in
      // given
      world.catalogOutcome = .models([])
      let workflow = world.loginWorkflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .success)
      #expect(world.storedCredential?.profileID == AuthFixture.freshProfileID)
      #expect(world.terminal.transcript.contains("CLAW_LLM_MODEL=openai-chatgpt/<model>"))
    }
  }

  @Test func theCatalogIsFetchedWithTheCredentialLoginJustStored() async throws {
    try await withAuthWorld("auth-login-catalog-bearer") { world in
      // given
      let workflow = world.loginWorkflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .success)
      let seen = try #require(world.seenCatalogAuthorization)
      #expect(seen.headers["Authorization"] == "Bearer \(AuthFixture.accessToken)")
    }
  }
}
