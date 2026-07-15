import Foundation

#if canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

/// The publication protocol's own error vocabulary. Callers translate it into their seam type
/// (`SecretStoreError`, `LLMCredentialStoreError`) — it never leaves `ClawSecrets`, and it carries
/// only state-root filenames, never an absolute path and never bytes read from a file.
enum SecureFileError: Error, Sendable, Equatable {
  /// Metadata policy refused the entry: not a regular file, wrong owner, or wrong mode.
  case insecure(String)
  case unreadable(String)
  case oversized(String)
  /// Nothing was renamed. Whatever the target held before, it still holds.
  case publicationFailed(String)
}

/// Everything one `fstat`/`lstat` tells the protocol about an entry.
struct SecureFileFacts: Sendable, Equatable {
  let device: dev_t
  let inode: ino_t
  let isRegularFile: Bool
  let permissionBits: UInt32
  let ownerUID: uid_t
  let byteCount: Int

  var identity: SecureFileIdentity {
    SecureFileIdentity(
      device: device,
      inode: inode,
      ownerUID: ownerUID,
      permissionBits: permissionBits
    )
  }
}

/// The subset of an entry's facts that pins it to one specific file. Rollback records this at
/// creation time and demands an exact match before unlinking, so a path whose contents were
/// swapped underneath the operation is left alone.
struct SecureFileIdentity: Sendable, Equatable {
  let device: dev_t
  let inode: ino_t
  let ownerUID: uid_t
  let permissionBits: UInt32
}

/// Crash-safe publication and bounded, no-follow reads for the files `SecretStatePaths` names.
///
/// The type encodes the distinction the callers depend on: **throwing means nothing was renamed**,
/// so the previous value is intact and a retry is free. **Returning means the rename landed** —
/// either durably or, when the parent directory could not be proven synced, uncertainly. A caller
/// holding an uncertain outcome must reload the path rather than assume the write was lost.
struct SecureFilePublisher: Sendable {
  static let ownerOnlyPermissions: UInt32 = 0o600
  /// Strips the file-type bits from `st_mode`.
  static let permissionBitsMask: UInt32 = 0o777

  /// Deterministic injection points for the four failures the protocol must tell apart. Production
  /// constructs the publisher without one; nothing but a test ever sets it.
  enum Failpoint: Sendable, Equatable, CaseIterable {
    case tempWrite
    case fileSync
    case rename
    case directorySync
  }

  /// What an existing entry must satisfy before its bytes are read.
  struct ReadPolicy: Sendable, Equatable {
    let maximumByteCount: Int
    /// `nil` accepts any mode. The runtime envelope needs that: Foundation's atomic write created
    /// it 0644 in every installation sealed before this protocol existed, and that ciphertext's
    /// confidentiality rests on the mode-checked key, not on its own permissions. Demanding 0600
    /// there would lock owners out of secrets they can still legitimately decrypt.
    let requiredPermissionBits: UInt32?
  }

  /// The two ways a rename can have landed. There is no third: a publication that did not rename
  /// throws instead.
  enum PublicationOutcome: Sendable, Equatable {
    case published(SecureFileIdentity)
    /// The rename committed but the parent directory was not proven durable, so a crash now could
    /// still lose the new name. The bytes are readable at the path either way.
    case commitUncertain(SecureFileIdentity)

    var identity: SecureFileIdentity {
      switch self {
      case .published(let identity), .commitUncertain(let identity):
        return identity
      }
    }

    var isCommitUncertain: Bool {
      if case .commitUncertain = self {
        return true
      }
      return false
    }
  }

  private let failpoint: Failpoint?

  init(failpoint: Failpoint? = nil) {
    self.failpoint = failpoint
  }

  /// Publishes `bytes` at `url`: same-directory 0600 temp file, all bytes written, `fsync` the
  /// file, atomic `rename`, `fsync` the parent directory. The temp entry is unlinked on every path
  /// that does not rename it away.
  func publish(_ bytes: Data, to url: URL) throws(SecureFileError) -> PublicationOutcome {
    let name = url.lastPathComponent
    let directory = url.deletingLastPathComponent()
    let temporary = directory.appendingPathComponent(
      ".\(name).\(UInt64.random(in: 0..<UInt64.max)).tmp"
    )

    let descriptor = open(
      temporary.path,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
      mode_t(Self.ownerOnlyPermissions)
    )
    guard descriptor >= 0 else {
      throw .publicationFailed("create a temporary \(name)")
    }

    var renamed = false
    var descriptorOpen = true
    func closeOnce() {
      if descriptorOpen {
        close(descriptor)
        descriptorOpen = false
      }
    }
    defer {
      closeOnce()
      if !renamed {
        unlink(temporary.path)
      }
    }

    // O_CREAT's mode is filtered through the process umask, so state the mode outright rather than
    // inherit whatever the owner's shell happened to set.
    guard fchmod(descriptor, mode_t(Self.ownerOnlyPermissions)) == 0 else {
      throw .publicationFailed("set the mode of a temporary \(name)")
    }
    guard failpoint != .tempWrite, Self.writeAll(bytes, to: descriptor) else {
      throw .publicationFailed("write \(name)")
    }

    // Captured before the rename: `rename` moves the name, not the inode, so this is the identity
    // that will be sitting at the target.
    let identity = try Self.facts(ofDescriptor: descriptor, name: name).identity

    guard failpoint != .fileSync, fsync(descriptor) == 0 else {
      throw .publicationFailed("fsync \(name)")
    }
    guard failpoint != .rename, rename(temporary.path, url.path) == 0 else {
      throw .publicationFailed("rename \(name) into place")
    }
    renamed = true
    closeOnce()

    guard failpoint != .directorySync, Self.syncDirectory(directory) else {
      return .commitUncertain(identity)
    }
    return .published(identity)
  }

  /// Opens `url` without following symlinks, proves its metadata against `policy`, and reads its
  /// bytes. The size cap is checked against `fstat` before a byte of the payload is allocated.
  static func read(at url: URL, policy: ReadPolicy) throws(SecureFileError) -> Data {
    let name = url.lastPathComponent
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw .unreadable("open \(name)")
    }
    defer { close(descriptor) }

    let entry = try facts(ofDescriptor: descriptor, name: name)
    try validate(entry, name: name, policy: policy, expectedUID: getuid())

    guard let bytes = readAllBytes(descriptor, expecting: entry.byteCount) else {
      throw .unreadable("read \(name)")
    }
    return bytes
  }

  /// Unlinks `url` only if a fresh no-follow look still shows the exact entry the caller recorded
  /// creating. A file that predates the operation was never recorded, and one whose inode, owner,
  /// mode or file type changed underneath fails the match — so this can only ever remove its own
  /// work. Returns whether the entry was removed.
  @discardableResult
  static func removeCreatedEntry(_ identity: SecureFileIdentity, at url: URL) -> Bool {
    guard
      let facts = facts(ofEntryAt: url),
      facts.isRegularFile,
      facts.identity == identity
    else {
      return false
    }
    return unlink(url.path) == 0
  }

  /// `fsync` on the directory, which is what makes a rename survive a crash. Returns whether it
  /// was proven durable.
  @discardableResult
  static func syncDirectory(_ url: URL) -> Bool {
    let descriptor = open(url.path, O_RDONLY | O_DIRECTORY)
    guard descriptor >= 0 else {
      return false
    }
    defer { close(descriptor) }
    return fsync(descriptor) == 0
  }

  /// `lstat`, not `stat`: a dangling symlink is an entry that exists, and must force the encrypted
  /// backend rather than let a broken artifact read as absent.
  static func entryExists(at url: URL) -> Bool {
    var status = stat()
    return lstat(url.path, &status) == 0
  }

  /// The metadata rules, separated from the syscall that produces the facts. There is no portable
  /// way to chown to a foreign uid unprivileged, so that rule can only be proven with a synthetic
  /// uid — which requires the policy to be callable without a file behind it.
  static func validate(
    _ facts: SecureFileFacts,
    name: String,
    policy: ReadPolicy,
    expectedUID: uid_t
  ) throws(SecureFileError) {
    guard facts.isRegularFile else {
      throw .insecure("\(name) is not a regular file")
    }
    guard facts.ownerUID == expectedUID else {
      throw .insecure("\(name) is not owned by the daemon uid")
    }
    if let required = policy.requiredPermissionBits {
      guard facts.permissionBits == required else {
        throw .insecure("\(name) must be mode \(String(required, radix: 8))")
      }
    }
    guard facts.byteCount <= policy.maximumByteCount else {
      throw .oversized("\(name) exceeds \(policy.maximumByteCount) bytes")
    }
  }
}

// MARK: - Facts

extension SecureFilePublisher {
  static func facts(
    ofDescriptor descriptor: Int32,
    name: String
  ) throws(SecureFileError) -> SecureFileFacts {
    var status = stat()
    guard fstat(descriptor, &status) == 0 else {
      throw .unreadable("stat \(name)")
    }
    return facts(from: status)
  }

  static func facts(ofEntryAt url: URL) -> SecureFileFacts? {
    var status = stat()
    guard lstat(url.path, &status) == 0 else {
      return nil
    }
    return facts(from: status)
  }

  /// `st_mode` is `UInt16` on Darwin and `UInt32` on Linux; normalize to `UInt32` for both.
  private static func facts(from status: stat) -> SecureFileFacts {
    let mode = UInt32(status.st_mode)
    return SecureFileFacts(
      device: status.st_dev,
      inode: status.st_ino,
      isRegularFile: (mode & UInt32(S_IFMT)) == UInt32(S_IFREG),
      permissionBits: mode & permissionBitsMask,
      ownerUID: status.st_uid,
      byteCount: Int(status.st_size)
    )
  }
}

// MARK: - Bounded descriptor IO

private extension SecureFilePublisher {
  /// A short `write` is not an error and `EINTR` is not a failure — both mean "call it again".
  static func writeAll(_ bytes: Data, to descriptor: Int32) -> Bool {
    bytes.withUnsafeBytes { buffer in
      guard let base = buffer.baseAddress else {
        return true
      }
      var offset = 0
      while offset < buffer.count {
        let written = write(descriptor, base.advanced(by: offset), buffer.count - offset)
        if written < 0 {
          guard errno == EINTR else {
            return false
          }
          continue
        }
        offset += written
      }
      return true
    }
  }
}

/// A free function, not a member: `SecureFilePublisher.read` would otherwise shadow the `read`
/// syscall inside the type's own scope.
///
/// Reads at most `expected` bytes — the size the cap was already checked against — so a file
/// growing under the read cannot outrun the bound the caller was promised.
private func readAllBytes(_ descriptor: Int32, expecting expected: Int) -> Data? {
  var buffer = [UInt8](repeating: 0, count: expected)
  var offset = 0
  let succeeded = buffer.withUnsafeMutableBytes { raw -> Bool in
    guard let base = raw.baseAddress else {
      return true
    }
    while offset < expected {
      let count = read(descriptor, base.advanced(by: offset), expected - offset)
      if count < 0 {
        guard errno == EINTR else {
          return false
        }
        continue
      }
      if count == 0 {
        break
      }
      offset += count
    }
    return true
  }
  guard succeeded else {
    return nil
  }
  return Data(buffer[0..<offset])
}
