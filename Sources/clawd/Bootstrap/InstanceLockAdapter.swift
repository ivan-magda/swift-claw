import ClawAuth
import ClawCore
import ClawGateway
import ClawSecrets
import Foundation

/// The daemon's own single-instance `flock`, as the lock every mutating command asks for.
///
/// This type is the only one that knows both halves: a caller must not learn that a lock is a file,
/// and the daemon's lock must not learn that anything but the daemon takes it. One adapter rather
/// than one per command, so "held means the daemon is running" is decided in a single place.
struct InstanceLockAdapter: AuthMutationLocking {
  let path: String

  init(path: String) {
    self.path = path
  }

  init(stateRoot: URL) {
    self.init(path: SecretStatePaths(stateRoot: stateRoot).instanceLock.path)
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
