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
  /// Nothing was linked into place. Whatever the target held before, it still holds.
  case publicationFailed(String)
  /// An exclusive publication found the target name already taken, so it linked nothing. Only
  /// `PublicationMode.exclusive` can produce this; a replacing publication takes the name regardless.
  case alreadyExists(String)
}

/// Everything one `fstat`/`lstat` tells the protocol about an entry.
struct SecureFileFacts: Sendable, Equatable {
  let device: dev_t
  let inode: ino_t
  let isRegularFile: Bool
  let permissionBits: UInt32
  let ownerUID: uid_t
  let byteCount: Int
  let modificationNanoseconds: Int64

  var identity: SecureFileIdentity {
    SecureFileIdentity(
      device: device,
      inode: inode,
      ownerUID: ownerUID,
      permissionBits: permissionBits,
      byteCount: byteCount,
      modificationNanoseconds: modificationNanoseconds
    )
  }
}

/// The subset of an entry's facts that pins it to one specific file. Rollback records this at
/// creation time and demands an exact match before unlinking, so a path whose contents were
/// swapped underneath the operation is left alone. A (device, inode) pair alone is not that pin:
/// Linux filesystems reuse a freed inode number for the next file created, so size and mtime —
/// captured after the last write, and unchanged by the commit's fsync/rename — complete it.
struct SecureFileIdentity: Sendable, Equatable {
  let device: dev_t
  let inode: ino_t
  let ownerUID: uid_t
  let permissionBits: UInt32
  let byteCount: Int
  let modificationNanoseconds: Int64
}

/// Crash-safe publication and bounded, no-follow reads for the files `SecretStatePaths` names.
///
/// The type encodes the distinction the callers depend on: **throwing means nothing was linked into
/// place**, so the previous value is intact and a retry is free. **Returning means the commit
/// landed** — either durably or, when the parent directory could not be proven synced, uncertainly.
/// A caller holding an uncertain outcome must reload the path rather than assume the write was lost.
struct SecureFilePublisher: Sendable {
  static let ownerOnlyPermissions: UInt32 = 0o600
  /// Strips the file-type bits from `st_mode`.
  static let permissionBitsMask: UInt32 = 0o777

  /// A deterministic injection point for the four failures the protocol must tell apart. Production
  /// constructs the publisher without one; nothing but a test ever sets it.
  ///
  /// It names an entry as well as a step because one `seal` drives the same publisher for both the
  /// key and the envelope. A failpoint that could only say "fail the commit" would always fire on
  /// the key — the first publication — and a test meaning to exercise the envelope's rollback would
  /// quietly stop reaching the envelope at all.
  struct Failpoint: Sendable, Equatable {
    enum Step: Sendable, Equatable {
      case tempWrite
      case fileSync
      /// Claiming the target name: `rename` or `link` depending on the mode.
      case commit
      case directorySync
    }

    let step: Step
    /// The `lastPathComponent` this fires on. `nil` fires on every publication.
    let entry: String?

    init(_ step: Step, on entry: String? = nil) {
      self.step = step
      self.entry = entry
    }

    func fires(_ candidate: Step, on name: String) -> Bool {
      step == candidate && (entry == nil || entry == name)
    }
  }

  /// How a publication claims the target name.
  enum PublicationMode: Sendable, Equatable {
    /// `rename`: the target is meant to be replaced, and whatever holds the name is clobbered
    /// atomically.
    case replace
    /// `link`: the target must not already exist. A create-if-missing target cannot use `replace`,
    /// because `rename` would let the loser of a race unlink the winner's inode — and for the key
    /// that means unlinking the only bytes able to open the envelope published beside it.
    case exclusive
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

  /// The two ways a commit can have landed. There is no third: a publication that did not claim the
  /// target name throws instead.
  enum PublicationOutcome: Sendable, Equatable {
    case published(SecureFileIdentity)
    /// The name was claimed but the parent directory was not proven durable, so a crash now could
    /// still lose it. The bytes are readable at the path either way.
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
  /// file, claim the target name, `fsync` the parent directory. The temp entry is unlinked on every
  /// path, including the successful one. The bytes are durable on their own inode before the name
  /// ever points at them, so no crash can expose a half-written entry under the target name.
  ///
  /// `mode` decides only how the name is claimed; everything above it is identical.
  func publish(
    _ bytes: Data,
    to url: URL,
    mode: PublicationMode = .replace
  ) throws(SecureFileError) -> PublicationOutcome {
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

    var temporaryNameLives = true
    var descriptorOpen = true
    func closeOnce() {
      if descriptorOpen {
        close(descriptor)
        descriptorOpen = false
      }
    }
    defer {
      closeOnce()
      if temporaryNameLives {
        unlink(temporary.path)
      }
    }

    // O_CREAT's mode is filtered through the process umask, so state the mode outright rather than
    // inherit whatever the owner's shell happened to set.
    guard fchmod(descriptor, mode_t(Self.ownerOnlyPermissions)) == 0 else {
      throw .publicationFailed("set the mode of a temporary \(name)")
    }
    guard fires(.tempWrite, on: name) == false, Self.writeAll(bytes, to: descriptor) else {
      throw .publicationFailed("write \(name)")
    }

    // Captured before the commit: claiming the name attaches it to this inode without moving the
    // inode, so this is the identity that will be sitting at the target.
    let identity: SecureFileIdentity
    do {
      identity = try Self.facts(ofDescriptor: descriptor, name: name).identity
    } catch {
      // `facts` speaks the read path's vocabulary; here the failure is a failure to publish, and
      // pointing the owner at a read they never asked for would misdirect them.
      throw .publicationFailed("stat \(name)")
    }

    guard fires(.fileSync, on: name) == false, fsync(descriptor) == 0 else {
      throw .publicationFailed("fsync \(name)")
    }
    guard fires(.commit, on: name) == false else {
      throw .publicationFailed("commit \(name) into place")
    }
    try Self.claim(temporary, as: url, mode: mode, name: name)

    // `rename` consumed the temp name; `link` left it as a second name for the committed inode.
    // Drop it before the directory is synced so no crash can strand it.
    if mode == .exclusive {
      unlink(temporary.path)
    }
    temporaryNameLives = false
    closeOnce()

    guard syncDirectory(directory, forEntry: name) else {
      return .commitUncertain(identity)
    }
    return .published(identity)
  }

  /// The durability step on its own. A caller recovering an uncertain commit whose bytes already
  /// sit at the target retries exactly this rather than minting a second inode for bytes that are
  /// already there — and reaches the same failpoint the publication does, so a directory that
  /// cannot be synced stays unsynced for the retry too.
  func syncDirectory(_ directory: URL, forEntry name: String) -> Bool {
    guard fires(.directorySync, on: name) == false else {
      return false
    }
    return Self.syncDirectory(directory)
  }

  private func fires(_ step: Failpoint.Step, on name: String) -> Bool {
    failpoint?.fires(step, on: name) == true
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
  /// mode, file type, size or mtime changed underneath fails the match — so this can only ever
  /// remove its own work. Returns whether the entry was removed.
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

// MARK: - Name claiming

private extension SecureFilePublisher {
  /// The commit point. Returning means the target name now resolves to the temporary's inode;
  /// throwing means it does not, and whatever held the name still does.
  ///
  /// `link` is what makes exclusivity real rather than advisory: a check-then-`rename` can only
  /// narrow the race window, while `link` is refused by the kernel the instant the name is taken —
  /// no lock between the racing processes required.
  static func claim(
    _ temporary: URL,
    as url: URL,
    mode: PublicationMode,
    name: String
  ) throws(SecureFileError) {
    switch mode {
    case .replace:
      guard rename(temporary.path, url.path) == 0 else {
        throw .publicationFailed("rename \(name) into place")
      }
    case .exclusive:
      guard link(temporary.path, url.path) == 0 else {
        // `link` does not follow a symlink standing at the target, so a planted link is an entry
        // that exists rather than a name that redirects the write.
        guard errno == EEXIST else {
          throw .publicationFailed("link \(name) into place")
        }
        throw .alreadyExists(name)
      }
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
    #if canImport(Glibc)
      let modified = status.st_mtim
    #else
      let modified = status.st_mtimespec
    #endif
    return SecureFileFacts(
      device: status.st_dev,
      inode: status.st_ino,
      isRegularFile: (mode & UInt32(S_IFMT)) == UInt32(S_IFREG),
      permissionBits: mode & permissionBitsMask,
      ownerUID: status.st_uid,
      byteCount: Int(status.st_size),
      modificationNanoseconds: Int64(modified.tv_sec) * 1_000_000_000 + Int64(modified.tv_nsec)
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
