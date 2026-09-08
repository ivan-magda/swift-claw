import ClawAuth
import ClawCore
import ClawGateway
import ClawSecrets
import ClawSubprocess
import Foundation

/// The daemon's own single-instance `flock`, as the lock every mutating command asks for.
struct InstanceLockAdapter: AuthMutationLocking {
  let path: String

  init(path: String) {
    self.path = path
  }

  init(stateRoot: URL) {
    let statePaths = SecretStatePaths(stateRoot: stateRoot)
    self.init(path: statePaths.instanceLock.path)
  }

  func acquire() throws -> AuthMutationLease {
    let lock: InstanceLock
    do {
      lock = try InstanceLock(path: path)
    } catch InstanceLock.LockError.alreadyLocked {
      throw AuthMutationLockFailure.held
    } catch {
      throw AuthMutationLockFailure.unavailable(detail: "\(error)")
    }

    return AuthMutationLease {
      lock.release()
    }
  }
}
