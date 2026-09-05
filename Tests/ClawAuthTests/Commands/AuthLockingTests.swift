import ClawCore
import ClawGateway
import ClawSecrets
import ClawSubprocess
import Foundation
import Testing

@testable import ClawAuth

/// The adapter `clawd` supplies in production, written here so process ownership is proven against
/// the real `flock` the daemon takes rather than against a double that only ever agrees to fail.
struct RealInstanceLocking: AuthMutationLocking {
  let path: String
  let log: AuthEffectLog

  func acquire() throws -> AuthMutationLease {
    let lock: InstanceLock
    do {
      lock = try InstanceLock(path: path)
    } catch InstanceLock.LockError.alreadyLocked {
      throw AuthMutationLockFailure.held
    } catch {
      throw AuthMutationLockFailure.unavailable(detail: "\(error)")
    }

    log.record(.lockAcquired)
    let effects = log
    return AuthMutationLease {
      lock.release()
      effects.record(.lockReleased)
    }
  }
}

/// What the state root looks like from outside the workflow. A held-lock case that asserted only on
/// the workflow's own log would be believed by a workflow that had written the files anyway.
private func encryptedArtifacts(in world: AuthWorld) -> [Bool] {
  let manager = FileManager.default
  return [
    manager.fileExists(atPath: world.paths.key.path),
    manager.fileExists(atPath: world.paths.runtimeEnvelope.path),
    manager.fileExists(atPath: world.paths.credentialEnvelope.path),
  ]
}

@Suite struct AuthLockingTests {
  // MARK: - Login

  /// The whole ordering claim in one case, and the reason it cannot pass vacuously: the second half
  /// runs the same workflow over the same doubles with nothing changed but the lock. A login broken
  /// for every input would fail the release phase.
  @Test func loginWaitsForTheDaemonToStopAndThenProceeds() async throws {
    try await withAuthWorld("auth-lock-login") { world in
      // given — a daemon holds the state root's instance lock
      let daemon = try InstanceLock(path: world.paths.instanceLock.path)
      world.mutationLock = RealInstanceLocking(
        path: world.paths.instanceLock.path,
        log: world.log
      )
      let workflow = world.loginWorkflow()

      // when
      let blocked = await workflow.login()

      // then
      #expect(blocked.exit == .commandFailure)
      #expect(world.terminal.transcript.lowercased().contains("stop"))
      #expect(world.log.recorded.isEmpty)
      #expect(encryptedArtifacts(in: world) == [false, false, false])

      // when — the daemon stops
      daemon.release()
      let allowed = await workflow.login()

      // then
      #expect(allowed.exit == .success)
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
      #expect(encryptedArtifacts(in: world) == [true, true, true])
    }
  }

  /// The lease is the daemon's way back in. A login that kept the lock would leave the owner unable
  /// to restart the very daemon the command told them to stop.
  @Test func aFinishedLoginLeavesTheLockForTheDaemonToTake() async throws {
    try await withAuthWorld("auth-lock-released") { world in
      // given
      world.mutationLock = RealInstanceLocking(
        path: world.paths.instanceLock.path,
        log: world.log
      )
      let workflow = world.loginWorkflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .success)
      let daemon = try InstanceLock(path: world.paths.instanceLock.path)
      daemon.release()
    }
  }

  /// A login that fails must give the lock back just as surely as one that succeeds.
  @Test func aFailedLoginAlsoLeavesTheLockForTheDaemonToTake() async throws {
    try await withAuthWorld("auth-lock-released-on-failure") { world in
      // given
      world.mutationLock = RealInstanceLocking(
        path: world.paths.instanceLock.path,
        log: world.log
      )
      world.deviceOutcome = .failure { ChatGPTOAuthFailure.deadlineExceeded }
      let workflow = world.loginWorkflow()

      // when
      let result = await workflow.login()

      // then
      #expect(result.exit == .commandFailure)
      #expect(world.log.recorded.last == .lockReleased)
      let daemon = try InstanceLock(path: world.paths.instanceLock.path)
      daemon.release()
    }
  }

  // MARK: - Logout

  @Test func logoutWaitsForTheDaemonToStopAndThenProceeds() async throws {
    try await withAuthWorld("auth-lock-logout") { world in
      // given
      try world.seedPriorLogin()
      let daemon = try InstanceLock(path: world.paths.instanceLock.path)
      world.mutationLock = RealInstanceLocking(
        path: world.paths.instanceLock.path,
        log: world.log
      )
      let workflow = world.logoutWorkflow()

      // when
      let blocked = workflow.logout()

      // then
      #expect(blocked.exit == .commandFailure)
      #expect(blocked.transcript.lowercased().contains("stop"))
      #expect(world.log.recorded.isEmpty)
      #expect(try world.loadStoredCredential() == AuthFixture.priorCredential)

      // when — the daemon stops
      daemon.release()
      let allowed = workflow.logout()

      // then
      #expect(allowed.exit == .success)
      #expect(try world.loadStoredCredential() == nil)
      #expect(FileManager.default.fileExists(atPath: world.paths.credentialEnvelope.path))
      #expect(world.log.recorded.contains(.credentialDeleted))
    }
  }
}
