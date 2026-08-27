#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

/// Cross-process single-instance guard via `flock` on a held-open file descriptor.
/// The kernel drops the lock when the process exits — graceful, signalled, or crashed — so a
/// dead daemon frees the lock with no stale-PID cleanup. Hold the instance for the
/// daemon's entire lifetime; releasing or deallocating it relinquishes the lock.
package final class InstanceLock: @unchecked Sendable {
  package enum LockError: Error, Sendable, Equatable {
    case openFailed(errno: Int32)
    case insecureLockFile
    case alreadyLocked
  }

  private static let lockFileMode: mode_t = 0o600

  private let fileDescriptor: Int32
  private var released = false

  package init(path: String) throws {
    let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, Self.lockFileMode)
    guard descriptor >= 0 else {
      throw errno == ELOOP ? LockError.insecureLockFile : LockError.openFailed(errno: errno)
    }
    guard Self.secure(descriptor) else {
      close(descriptor)
      throw LockError.insecureLockFile
    }

    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let lockErrno = errno
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

  package func release() {
    guard !released else { return }
    released = true
    flock(fileDescriptor, LOCK_UN)
    close(fileDescriptor)
  }

  private static func secure(_ descriptor: Int32) -> Bool {
    var status = stat()
    guard
      fstat(descriptor, &status) == 0,
      (status.st_mode & S_IFMT) == S_IFREG,
      status.st_nlink == 1,
      status.st_uid == geteuid(),
      fchmod(descriptor, lockFileMode) == 0,
      fstat(descriptor, &status) == 0
    else {
      return false
    }
    return (status.st_mode & S_IFMT) == S_IFREG
      && status.st_nlink == 1
      && status.st_uid == geteuid()
      && (status.st_mode & mode_t(0o777)) == lockFileMode
  }
}
