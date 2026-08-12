import Foundation
import Synchronization

// MARK: - Failures

/// Why the state root is not this process's to change right now.
///
/// The two cases are separate because the remedies are: one is answered by stopping the daemon, and
/// the other is not answered by stopping anything. Telling an owner to stop a daemon that is not
/// running would send them looking for a process that was never the problem.
public enum AuthMutationLockFailure: Error, Sendable, Equatable {
  /// Something else already owns the state root — the daemon, or a second auth command.
  case held
  /// The lock could not be opened at all.
  case unavailable(detail: String)
}

// MARK: - The Lease

/// The right to mutate the state root, held until it is given back.
///
/// It is close-once by construction rather than by convention: a mutating command releases on every
/// exit it has, and several of those exits overlap on the way out. Releasing twice must not be able
/// to free a lock a *later* command has since taken.
public struct AuthMutationLease: Sendable {
  private let box: ReleaseBox

  public init(release: @escaping @Sendable () -> Void) {
    box = ReleaseBox(release)
  }

  public func release() {
    box.releaseOnce()
  }
}

private final class ReleaseBox: Sendable {
  private let stored: Mutex<(@Sendable () -> Void)?>

  init(_ release: @escaping @Sendable () -> Void) {
    stored = Mutex(release)
  }

  /// Takes the action out under the lock and runs it outside: two racing releases cannot both find
  /// one, and the release itself never runs while the lock is held.
  func releaseOnce() {
    let action = stored.withLock { current -> (@Sendable () -> Void)? in
      let taken = current
      current = nil
      return taken
    }
    action?()
  }
}

// MARK: - Locking

/// Whatever actually owns the state root. `clawd` supplies the adapter over the daemon's instance
/// lock; nothing here knows that a lock is a file, let alone which file — which is what keeps the
/// auth workflow off the daemon's infrastructure module.
public protocol AuthMutationLocking: Sendable {
  func acquire() throws -> AuthMutationLease
}

// MARK: - Coordinator

/// The gate every mutating command passes. Its whole contract is an ordering: a caller that has no
/// lease has not been given one, and therefore has not sealed a secret, written a credential, or
/// said a word to a vendor. Making that the shape of the API rather than a rule in a comment is what
/// stops the next command from doing its first side effect and then asking.
public struct AuthMutationCoordinator: Sendable {
  private let lock: any AuthMutationLocking

  public init(lock: any AuthMutationLocking) {
    self.lock = lock
  }

  /// The lease, or why there is none. It reports rather than throws because the caller's next move
  /// is to render the refusal and exit, not to unwind.
  func acquire() -> Result<AuthMutationLease, AuthMutationLockFailure> {
    do {
      return .success(try lock.acquire())
    } catch let failure as AuthMutationLockFailure {
      return .failure(failure)
    } catch {
      // An adapter that failed for a reason it did not name still denies the lease. Guessing
      // "held" would tell an owner to stop a daemon that may not be running.
      return .failure(.unavailable(detail: "\(error)"))
    }
  }
}
