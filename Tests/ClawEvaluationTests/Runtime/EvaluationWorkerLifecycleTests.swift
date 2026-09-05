import ClawAgent
import ClawCore
import ClawSubprocess
import ClawTestSupport
import Foundation
import Synchronization
import Testing

@testable import ClawEvaluation
@testable import ClawSecrets

@Suite struct EvaluationWorkerLifecycleTests {
  @Test func workerLifecycleOwnsTheProductionLockAndShutsDownInOrder() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let stateRoot = root.appendingPathComponent("state")
    let credentialStateRoot = root.appendingPathComponent("credential-state")
    let events = LifecycleEvents()

    // when
    let value = try await EvaluationWorkerLifecycle.withProductionLock(
      stateRoot: stateRoot,
      credentialStateRoot: credentialStateRoot,
      makeResource: {
        let lockPath = stateRoot.appendingPathComponent("clawd.lock").path
        do {
          let unexpected = try InstanceLock(path: lockPath)
          unexpected.release()
          await events.append("resource_without_lock")
        } catch InstanceLock.LockError.alreadyLocked {
          await events.append("resource_under_lock")
        }
        return RecordingLifecycleResource(events: events)
      },
      operation: { _, _ in
        await events.append("operation")
        return 7
      }
    )
    let reacquired = try InstanceLock(path: stateRoot.appendingPathComponent("clawd.lock").path)
    reacquired.release()

    // then
    #expect(value == 7)
    #expect(
      await events.values
        == ["resource_under_lock", "operation", "credentials_closed", "transport_closed"]
    )
  }

  @Test func twoRootLifecycleKeepsBothLocksThroughCredentialShutdown() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let stateRoot = root.appendingPathComponent("state")
    let credentialStateRoot = root.appendingPathComponent("credential-state")
    let events = LifecycleEvents()

    // when
    _ = try await EvaluationWorkerLifecycle.withProductionLock(
      stateRoot: stateRoot,
      credentialStateRoot: credentialStateRoot,
      makeResource: {
        LockObservingLifecycleResource(
          stateRoot: stateRoot,
          credentialStateRoot: credentialStateRoot,
          events: events
        )
      },
      operation: { _, _ in 7 }
    )
    let stateIsFree = try EvaluationWorkerLifecycle.proveProductionLockIsFree(
      stateRoot: stateRoot
    )
    let credentialIsFree = try EvaluationWorkerLifecycle.proveProductionLockIsFree(
      stateRoot: credentialStateRoot
    )

    // then
    #expect(await events.values == ["state_locked", "credential_locked", "transport_closed"])
    #expect(stateIsFree)
    #expect(credentialIsFree)
  }

  @Test func twoRootLifecycleCoalescesEqualRoots() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let stateRoot = root.appendingPathComponent("state")

    // when
    let value = try await EvaluationWorkerLifecycle.withProductionLock(
      stateRoot: stateRoot,
      credentialStateRoot: stateRoot,
      makeResource: { RecordingLifecycleResource(events: LifecycleEvents()) },
      operation: { _, _ in 7 }
    )

    // then
    #expect(value == 7)
    #expect(try EvaluationWorkerLifecycle.proveProductionLockIsFree(stateRoot: stateRoot))
  }

  @Test func twoRootLifecycleAcquiresM3StateBeforeCredentialState() async throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let stateRoot = root.appendingPathComponent("state")
    let credentialStateRoot = root.appendingPathComponent("credential-state")
    try EvaluationPathSecurity.ensurePrivateDirectory(at: stateRoot)
    let stateLock = try InstanceLock(path: SecretStatePaths(stateRoot: stateRoot).instanceLock.path)
    defer { stateLock.release() }
    let credentialLockURL = SecretStatePaths(stateRoot: credentialStateRoot).instanceLock

    // when
    let error = await #expect(throws: InstanceLock.LockError.alreadyLocked) {
      _ = try await EvaluationWorkerLifecycle.withProductionLock(
        stateRoot: stateRoot,
        credentialStateRoot: credentialStateRoot,
        makeResource: { RecordingLifecycleResource(events: LifecycleEvents()) },
        operation: { _, _ in 7 }
      )
    }

    // then — reversed acquisition would create the credential lock file before state contention.
    #expect(error != nil)
    #expect(FileManager.default.fileExists(atPath: credentialLockURL.path) == false)
  }

  @Test func credentialRootRejectsEvaluationProductionNoncanonicalAndSymlinkPaths() throws {
    // given
    let root = try makeEvaluationTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let evaluationRoot = root.appendingPathComponent("evaluation")
    let legacyStateRoot = evaluationRoot.appendingPathComponent("state")
    let externalRoot = root.appendingPathComponent("credential-state")
    let symlinkRoot = root.appendingPathComponent("credential-link")
    try FileManager.default.createDirectory(at: evaluationRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: externalRoot)
    let productionRoot = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".swift-claw")

    // when / then
    #expect(
      throws: EvaluationCredentialStateRootError.evaluationStateForbidden
    ) {
      try EvaluationCredentialStateRoot.validate(
        path: evaluationRoot.appendingPathComponent("credentials").path,
        evaluationRoot: evaluationRoot
      )
    }
    #expect(throws: EvaluationCredentialStateRootError.productionStateForbidden) {
      try EvaluationCredentialStateRoot.validate(
        path: productionRoot.path,
        evaluationRoot: evaluationRoot
      )
    }
    #expect(throws: EvaluationCredentialStateRootError.noncanonical) {
      try EvaluationCredentialStateRoot.validate(
        path: externalRoot.appendingPathComponent("..").path,
        evaluationRoot: evaluationRoot
      )
    }
    #expect(throws: EvaluationCredentialStateRootError.noncanonical) {
      try EvaluationCredentialStateRoot.validate(
        path: symlinkRoot.path,
        evaluationRoot: evaluationRoot
      )
    }
    #expect(
      try EvaluationCredentialStateRoot.validate(
        path: externalRoot.path,
        evaluationRoot: evaluationRoot
      ).path == externalRoot.path
    )
    #expect(throws: EvaluationCredentialStateRootError.legacyStateMismatch) {
      try EvaluationCredentialStateRoot.validateLegacy(
        path: externalRoot.path,
        expectedStateRoot: legacyStateRoot
      )
    }
    #expect(
      try EvaluationCredentialStateRoot.validateLegacy(
        path: legacyStateRoot.path,
        expectedStateRoot: legacyStateRoot
      ).path == legacyStateRoot.path
    )
  }

  #if os(macOS)
    @Test func credentialRootAcceptsCanonicalPrivateTemporaryPathAndRejectsAlias() throws {
      // given
      let directoryName = "swift-claw-credential-state-\(UUID().uuidString)"
      let canonicalRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent(directoryName, isDirectory: true)
      let evaluationRoot = canonicalRoot.appendingPathComponent("evaluation", isDirectory: true)
      let credentialRoot = canonicalRoot.appendingPathComponent("credentials", isDirectory: true)
      let aliasCredentialRoot = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent(directoryName, isDirectory: true)
        .appendingPathComponent("credentials", isDirectory: true)
      try FileManager.default.createDirectory(at: evaluationRoot, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: credentialRoot, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: canonicalRoot) }

      // when
      let validated = try EvaluationCredentialStateRoot.validate(
        path: credentialRoot.path,
        evaluationRoot: evaluationRoot
      )
      let aliasError = #expect(throws: EvaluationCredentialStateRootError.noncanonical) {
        try EvaluationCredentialStateRoot.validate(
          path: aliasCredentialRoot.path,
          evaluationRoot: evaluationRoot
        )
      }

      // then
      #expect(validated.path == credentialRoot.path)
      #expect(aliasError != nil)
    }
  #endif

  @Test func operationAndCredentialShutdownFailureStillClosesTransportAndFailsIntegrity() async {
    // given
    let events = LifecycleEvents()

    // when
    let error = await #expect(throws: EvaluationWorkerLifecycleError.self) {
      _ = try await EvaluationWorkerLifecycle.withResource(
        makeResource: { FailingLifecycleResource(events: events) },
        operation: { _ -> Int in
          await events.append("operation_failed")
          throw LifecycleTestError.operation
        }
      )
    }

    // then
    #expect(error != nil)
    #expect(
      await events.values
        == ["operation_failed", "credentials_failed", "transport_closed"]
    )
  }
}

private actor LifecycleEvents {
  private var stored: [String] = []

  var values: [String] { stored }

  func append(_ value: String) {
    stored.append(value)
  }
}

private struct RecordingLifecycleResource: EvaluationWorkerResource {
  let events: LifecycleEvents

  func shutdownCredentials() async throws {
    await events.append("credentials_closed")
  }

  func shutdownTransport() async throws {
    await events.append("transport_closed")
  }
}

private enum LifecycleTestError: Error {
  case operation
  case credentials
}

private struct FailingLifecycleResource: EvaluationWorkerResource {
  let events: LifecycleEvents

  func shutdownCredentials() async throws {
    await events.append("credentials_failed")
    throw LifecycleTestError.credentials
  }

  func shutdownTransport() async throws {
    await events.append("transport_closed")
  }
}

private struct LockObservingLifecycleResource: EvaluationWorkerResource {
  let stateRoot: URL
  let credentialStateRoot: URL
  let events: LifecycleEvents

  func shutdownCredentials() async throws {
    await recordLockState(root: stateRoot, locked: "state_locked", free: "state_free")
    await recordLockState(
      root: credentialStateRoot,
      locked: "credential_locked",
      free: "credential_free"
    )
  }

  func shutdownTransport() async throws {
    await events.append("transport_closed")
  }

  private func recordLockState(root: URL, locked: String, free: String) async {
    do {
      let lock = try InstanceLock(path: SecretStatePaths(stateRoot: root).instanceLock.path)
      lock.release()
      await events.append(free)
    } catch InstanceLock.LockError.alreadyLocked {
      await events.append(locked)
    } catch {
      await events.append("lock_error")
    }
  }
}
