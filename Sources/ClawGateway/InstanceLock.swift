#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

/// Cross-process single-instance guard via `flock` on a held-open file descriptor.
/// The kernel drops the lock when the process exits — graceful, signalled, or crashed — so a
/// dead daemon frees the lock with no stale-PID cleanup. Hold the instance for the
/// daemon's entire lifetime; releasing or deallocating it relinquishes the lock.
public final class InstanceLock: @unchecked Sendable {
  public enum LockError: Error, Sendable, Equatable {
    case openFailed(errno: Int32)
    case alreadyLocked
  }

  /// Owner-only (rw) permissions for the freshly created lock file.
  private static let lockFileMode: mode_t = 0o600

  private let fileDescriptor: Int32
  private var released = false

  /// Acquires an exclusive, non-blocking lock, throwing `.alreadyLocked` when another
  /// instance already holds it. The descriptor stays open for the lock's lifetime.
  public init(path: String) throws {
    let descriptor = open(path, O_CREAT | O_RDWR, Self.lockFileMode)
    guard descriptor >= 0 else {
      throw LockError.openFailed(errno: errno)
    }

    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let lockErrno = errno  // capture before close(), which overwrites errno
      close(descriptor)
      throw lockErrno == EWOULDBLOCK
        ? LockError.alreadyLocked
        : LockError.openFailed(errno: lockErrno)
    }

    fileDescriptor = descriptor
  }

  deinit {
    if !released {
      close(fileDescriptor)
    }
  }

  /// Idempotent: releasing the flock and closing the descriptor. Closing alone would free
  /// the lock; the explicit `LOCK_UN` makes the intent legible at the call site.
  public func release() {
    guard !released else {
      return
    }

    released = true

    flock(fileDescriptor, LOCK_UN)
    close(fileDescriptor)
  }
}
