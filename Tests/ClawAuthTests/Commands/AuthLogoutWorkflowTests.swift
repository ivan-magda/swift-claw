import ClawCore
import ClawSecrets
import ClawTestSupport
import Foundation
import Testing

@testable import ClawAuth

@Suite struct AuthLogoutWorkflowTests {
  @Test func logoutTakesTheLockDeletesTheRecordAndReleasesIt() async throws {
    try await withAuthWorld("auth-logout") { world in
      // given
      try world.seedPriorLogin()
      let workflow = world.logoutWorkflow()

      // when
      let result = workflow.logout()

      // then
      #expect(result.exit == .success)
      #expect(
        world.log.recorded == [
          .lockAcquired,
          .credentialStoreOpened,
          .credentialLoaded,
          .credentialDeleted,
          .lockReleased,
        ]
      )
      #expect(try world.loadStoredCredential() == nil)
      #expect(FileManager.default.fileExists(atPath: world.paths.credentialEnvelope.path))
    }
  }

  @Test func logoutSaysTheDeletionIsLocalRatherThanARevocation() async throws {
    try await withAuthWorld("auth-logout-wording") { world in
      // given
      try world.seedPriorLogin()
      let workflow = world.logoutWorkflow()

      // when
      let result = workflow.logout()

      // then
      let transcript = result.transcript.lowercased()
      #expect(transcript.contains("local"))
      #expect(transcript.contains("revocation") || transcript.contains("revoke"))
    }
  }

  @Test func logoutIsIdempotent() async throws {
    try await withAuthWorld("auth-logout-idempotent") { world in
      // given
      try world.seedPriorLogin()
      let workflow = world.logoutWorkflow()
      #expect(workflow.logout().exit == .success)

      // when
      let second = workflow.logout()

      // then
      #expect(second.exit == .success)
      #expect(second.transcript.lowercased().contains("already logged out"))
    }
  }

  @Test func logoutOnARootThatNeverHeldACredentialSucceeds() async throws {
    try await withAuthWorld("auth-logout-never") { world in
      // given
      let workflow = world.logoutWorkflow()

      // when
      let result = workflow.logout()

      // then
      #expect(result.exit == .success)
      #expect(result.transcript.lowercased().contains("already logged out"))
      #expect(world.log.recorded.contains(.credentialDeleted) == false)
    }
  }

  @Test func aHeldLockStopsLogoutBeforeItReadsOrDeletesAnything() async throws {
    try await withAuthWorld("auth-logout-locked") { world in
      // given
      try world.seedPriorLogin()
      world.lockFailure = .held
      let workflow = world.logoutWorkflow()

      // when
      let result = workflow.logout()

      // then
      #expect(result.exit == .commandFailure)
      #expect(result.transcript.lowercased().contains("stop"))
      #expect(world.log.recorded.isEmpty)
      // The credential the daemon is using is exactly as it was.
      #expect(try world.loadStoredCredential() == AuthFixture.priorCredential)
    }
  }
}
