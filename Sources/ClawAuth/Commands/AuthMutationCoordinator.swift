import Foundation
import Synchronization

// MARK: - Failures

public enum AuthMutationLockFailure: Error, Sendable, Equatable {
  /// Something else already owns the state root — the daemon, or a second auth command.
  case held
  /// The lock could not be opened at all.
  case unavailable(detail: String)
}

// MARK: - The Lease

/// The right to mutate the state root, held until it is given back.
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

public protocol AuthMutationLocking: Sendable {
  func acquire() throws -> AuthMutationLease
}

// MARK: - Coordinator

public struct AuthMutationCoordinator: Sendable {
  private let lock: any AuthMutationLocking

  public init(lock: any AuthMutationLocking) {
    self.lock = lock
  }

  func acquire() -> Result<AuthMutationLease, AuthMutationLockFailure> {
    do {
      return .success(try lock.acquire())
    } catch let failure as AuthMutationLockFailure {
      return .failure(failure)
    } catch {
      return .failure(.unavailable(detail: "\(error)"))
    }
  }
}
