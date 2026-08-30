import ClawSecrets
import ClawSubprocess
import Foundation

protocol EvaluationWorkerResource: Sendable {
  func shutdownCredentials() async throws
  func shutdownTransport() async throws
}

enum EvaluationCredentialStateRootError: Error, Sendable, Equatable {
  case noncanonical
  case unavailable
  case evaluationStateForbidden
  case productionStateForbidden
}

enum EvaluationCredentialStateRoot {
  static func validate(path: String, evaluationRoot: URL) throws -> URL {
    guard path.hasPrefix("/") else {
      throw EvaluationCredentialStateRootError.noncanonical
    }
    let candidate = URL(fileURLWithPath: path, isDirectory: true)
    guard
      candidate.standardizedFileURL.path == path,
      candidate.resolvingSymlinksInPath().path == path
    else {
      throw EvaluationCredentialStateRootError.noncanonical
    }
    let isEvaluationState = EvaluationPathSecurity.isContainedOrEqual(
      candidate,
      under: evaluationRoot
    )
    guard isEvaluationState == false else {
      throw EvaluationCredentialStateRootError.evaluationStateForbidden
    }
    let productionRoot = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".swift-claw", isDirectory: true)
      .standardizedFileURL
    let isProductionState = EvaluationPathSecurity.isContainedOrEqual(
      candidate,
      under: productionRoot
    )
    guard isProductionState == false else {
      throw EvaluationCredentialStateRootError.productionStateForbidden
    }
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw EvaluationCredentialStateRootError.unavailable
    }
    try EvaluationPathSecurity.rejectSymlinkComponents(in: [candidate])
    return candidate
  }
}

enum EvaluationWorkerLifecycle {
  package static func withProductionLock<Resource: EvaluationWorkerResource, Value: Sendable>(
    stateRoot: URL,
    credentialStateRoot: URL,
    makeResource: @Sendable () async throws -> Resource,
    operation: @Sendable (Resource, UUID) async throws -> Value
  ) async throws -> Value {
    try EvaluationPathSecurity.ensurePrivateDirectory(at: stateRoot)
    try EvaluationPathSecurity.ensurePrivateDirectory(at: credentialStateRoot)

    let stateLock = try InstanceLock(
      path: SecretStatePaths(stateRoot: stateRoot).instanceLock.path
    )
    let lockAcquisitionID = UUID()
    do {
      if stateRoot.standardizedFileURL.path == credentialStateRoot.standardizedFileURL.path {
        let value = try await withResource(makeResource: makeResource) { resource in
          try await operation(resource, lockAcquisitionID)
        }
        stateLock.release()
        return value
      }
      let credentialLock = try InstanceLock(
        path: SecretStatePaths(stateRoot: credentialStateRoot).instanceLock.path
      )
      do {
        let value = try await withResource(makeResource: makeResource) { resource in
          try await operation(resource, lockAcquisitionID)
        }
        credentialLock.release()
        stateLock.release()
        return value
      } catch {
        credentialLock.release()
        throw error
      }
    } catch {
      stateLock.release()
      throw error
    }
  }

  package static func withProductionLockOnly<Value: Sendable>(
    stateRoot: URL,
    operation: @Sendable (UUID) async throws -> Value
  ) async throws -> Value {
    try EvaluationPathSecurity.ensurePrivateDirectory(at: stateRoot)

    let lockPath = SecretStatePaths(stateRoot: stateRoot).instanceLock.path
    let lock = try InstanceLock(path: lockPath)
    let lockAcquisitionID = UUID()
    do {
      let value = try await operation(lockAcquisitionID)
      lock.release()
      return value
    } catch {
      lock.release()
      throw error
    }
  }

  static func proveProductionLockIsFree(stateRoot: URL) throws -> Bool {
    try EvaluationPathSecurity.ensurePrivateDirectory(at: stateRoot)
    let lock = try InstanceLock(path: SecretStatePaths(stateRoot: stateRoot).instanceLock.path)
    lock.release()
    return true
  }

  package static func withResource<Resource: EvaluationWorkerResource, Value: Sendable>(
    makeResource: @Sendable () async throws -> Resource,
    operation: @Sendable (Resource) async throws -> Value
  ) async throws -> Value {
    let resource = try await makeResource()
    let value: Value
    do {
      value = try await operation(resource)
    } catch let operationError {
      var cleanupErrors: [String] = []
      do {
        try await resource.shutdownCredentials()
      } catch {
        cleanupErrors.append("credentials:\(String(reflecting: error))")
      }
      do {
        try await resource.shutdownTransport()
      } catch {
        cleanupErrors.append("transport:\(String(reflecting: error))")
      }
      guard cleanupErrors.isEmpty else {
        throw EvaluationWorkerLifecycleError.operationAndCleanupFailed(
          operation: String(reflecting: operationError),
          cleanup: cleanupErrors
        )
      }
      throw operationError
    }
    do {
      try await resource.shutdownCredentials()
    } catch {
      try? await resource.shutdownTransport()
      throw error
    }
    do {
      try await resource.shutdownTransport()
    } catch {
      throw error
    }
    return value
  }
}

enum EvaluationWorkerLifecycleError: Error, Sendable, Equatable {
  case operationAndCleanupFailed(operation: String, cleanup: [String])
}
