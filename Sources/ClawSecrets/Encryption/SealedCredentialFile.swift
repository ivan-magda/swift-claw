import ClawCore
import Crypto
import Foundation

// MARK: - Plaintext Contract

/// The plaintext inside a sealed credential envelope: a versioned map of records.
///
/// `version` is a stored property rather than a computed constant so a map that reached disk without
/// one is refused instead of read as current, and `empty` is what a store publishes when there is
/// nothing on disk yet.
protocol SealedCredentialMap: Codable, Equatable, Sendable {
  static var currentVersion: Int { get }
  static var empty: Self { get }

  var version: Int { get }
}

// MARK: - The File

/// The AES-GCM envelope file both credential stores are built on: serialized read-modify-write,
/// crash-safe publication, and a proven-durable commit before any caller is told a credential was
/// saved.
///
/// One implementation rather than one per store. The uncertain-commit recovery below is the part
/// nobody notices is missing until a machine loses power, so a second copy of it is a copy that
/// eventually differs.
struct SealedCredentialFile<Map: SealedCredentialMap>: Sendable {
  static var maximumEnvelopeByteCount: Int { AESGCMEnvelope.maximumByteCount }

  /// Neither credential file has ever been written by anything but the protocol below, so both can
  /// demand the mode a secret deserves — unlike the runtime envelope, whose 0644 predates it and
  /// must keep opening.
  static var readPolicy: SecureFilePublisher.ReadPolicy {
    SecureFilePublisher.ReadPolicy(
      maximumByteCount: maximumEnvelopeByteCount,
      requiredPermissionBits: SecureFilePublisher.ownerOnlyPermissions
    )
  }

  private let paths: SecretStatePaths
  private let entry: SecretCredentialEntry
  private let codec: AESGCMEnvelope
  private let publisher: SecureFilePublisher
  /// Serializes read-modify-write cycles that share this one instance. Two interleaved saves would
  /// each read the same map and publish their own record, dropping the other's — silent credential
  /// loss. The lock lives on the instance, so it guards only concurrent callers of the same store;
  /// safety across separately constructed stores against one state root is owned elsewhere — by the
  /// daemon's credential actor and by the instance lock the mutating CLI commands hold.
  private let mutation = NSLock()

  init(
    stateRoot: URL,
    entry: SecretCredentialEntry,
    codec: AESGCMEnvelope,
    publisher: SecureFilePublisher
  ) {
    paths = SecretStatePaths(stateRoot: stateRoot)
    self.entry = entry
    self.codec = codec
    self.publisher = publisher
  }

  var url: URL { paths.url(for: entry) }

  /// Takes no lock. The commit is a rename, so a reader sees the whole old map or the whole new one
  /// and never a torn one; making readers queue behind a writer's fsync would buy nothing.
  func load() throws(CredentialStoreError) -> Map? {
    guard SecureFilePublisher.entryExists(at: url) else {
      return nil
    }
    return try loadMap(key: try openKey())
  }

  /// One serialized cycle: open the key, read the whole map, let `body` change it, publish the whole
  /// map back. `body` reports whether anything actually changed, so an already-absent record costs
  /// no rewrite — and cannot reseal an unchanged map under a fresh nonce.
  ///
  /// The lock is held across the entire cycle and never across an `await`: every step is a bounded
  /// synchronous syscall, so there is no suspension point at which a second mutation could interleave.
  func mutate(_ body: (inout Map) -> Bool) throws(CredentialStoreError) {
    mutation.lock()
    defer { mutation.unlock() }

    let key = try openKey()
    // A map that cannot be read is not overwritten. Preserving unrelated records is an invariant,
    // and blindly republishing over ciphertext this build cannot open would destroy records it was
    // never able to see.
    var map = try loadMap(key: key) ?? Map.empty
    guard body(&map) else {
      return
    }
    try publish(map, key: key)
  }
}

// MARK: - Publication

extension SealedCredentialFile {
  func publish(_ map: Map, key: SymmetricKey) throws(CredentialStoreError) {
    let outcome = try publishEnvelope(map, key: key)
    guard outcome.isCommitUncertain else {
      return
    }
    try recoverUncertainCommit(map, key: key)
  }

  /// The uncertain-commit contract. The bytes are readable at the target, but the rename that put
  /// them there is not proven to survive a crash — and a caller told "saved" will act on that: it
  /// will use the rotated credential, and the vendor has already invalidated the one the file would
  /// revert to. So the intended bytes being visible is never the answer here; a proven fsync is.
  /// Returning means durable, or this throws.
  func recoverUncertainCommit(_ intended: Map, key: SymmetricKey) throws(CredentialStoreError) {
    if readableMap(key: key) == intended {
      // The rename took and the bytes are the ones meant to be there, so only the parent directory's
      // durability is outstanding. Retry precisely that.
      guard publisher.syncDirectory(paths.directory, forEntry: entry.name) else {
        throw .commitUncertain
      }
      return
    }

    // Absent, stale, or unreadable — none of them are the intended map, so publish it once more and
    // demand both the file's and the parent's durability this time.
    guard try publishEnvelope(intended, key: key).isCommitUncertain == false else {
      throw .commitUncertain
    }
    guard readableMap(key: key) == intended else {
      throw .commitUncertain
    }
  }

  func publishEnvelope(
    _ map: Map,
    key: SymmetricKey
  ) throws(CredentialStoreError) -> SecureFilePublisher.PublicationOutcome {
    let envelope = try codec.sealCredential(try Self.encode(map), key: key)
    do {
      return try publisher.publish(envelope, to: url, mode: .replace)
    } catch {
      // Throwing from `publish` means the name was never claimed, so whatever the owner had is still
      // whole and the caller may retry as though nothing happened.
      throw Self.mapEnvelopeError(error)
    }
  }

  /// The map at the path, or nil if there is nothing there this build can read. Only recovery may
  /// use this: it is deciding whether the intended bytes arrived, and anything unreadable is by
  /// definition not them. Every other caller must see the typed refusal instead.
  func readableMap(key: SymmetricKey) -> Map? {
    guard let map = try? loadMap(key: key) else {
      return nil
    }
    return map
  }
}

// MARK: - Key And Envelope Files

private extension SealedCredentialFile {
  /// The map is sealed under the runtime key, so a state root without one has nothing to open with.
  /// "Seal your secrets first" and "your key's mode or owner is wrong" are separate problems with
  /// separate remedies, and the shared key-open path collapses both into one refusal — so the
  /// distinction is drawn here, from whether anything stands at the path at all.
  func openKey() throws(CredentialStoreError) -> SymmetricKey {
    guard SecureFilePublisher.entryExists(at: paths.key) else {
      throw .missingRuntimeKey
    }
    do {
      return try EncryptedFileSecretStore.openKey(at: paths.key)
    } catch {
      // Opening an existing key fails for exactly one reason: the protocol refuses its metadata or
      // its length.
      throw .insecureStorage
    }
  }

  func loadMap(key: SymmetricKey) throws(CredentialStoreError) -> Map? {
    guard SecureFilePublisher.entryExists(at: url) else {
      return nil
    }

    let envelope: Data
    do {
      envelope = try SecureFilePublisher.read(at: url, policy: Self.readPolicy)
    } catch {
      throw Self.mapEnvelopeError(error)
    }
    return try Self.decode(try codec.openCredential(envelope, key: key))
  }

  static func mapEnvelopeError(_ error: SecureFileError) -> CredentialStoreError {
    switch error {
    case .insecure, .unreadable:
      // Reached only once something has been seen standing at the path, so a no-follow open that
      // fails is the protocol refusing a planted symlink — not an absent file.
      return .insecureStorage
    case .oversized:
      return .oversizedStorage
    case .publicationFailed, .alreadyExists:
      // `.alreadyExists` is unreachable: these files are published to be replaced. Folding it in
      // rather than assuming it away keeps a future exclusive caller from being misdiagnosed.
      return .publicationFailed
    }
  }
}

// MARK: - Plaintext Coding

extension SealedCredentialFile {
  /// `.sortedKeys` is load-bearing rather than cosmetic. `Dictionary` iterates in an order derived
  /// from a per-process hash seed, so without it the same map would seal to different plaintext in
  /// every process.
  static func encode(_ map: Map) throws(CredentialStoreError) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let encoded = try? encoder.encode(map) else {
      throw .publicationFailed
    }
    return encoded
  }

  static func decode(_ plaintext: Data) throws(CredentialStoreError) -> Map {
    // The decoder's error quotes the bytes it choked on — which here are a decrypted token.
    // Discarding it entirely, rather than mapping it, is what keeps plaintext off this seam.
    guard let map = try? JSONDecoder().decode(Map.self, from: plaintext) else {
      throw .malformedStorage
    }
    guard map.version == Map.currentVersion else {
      throw .unsupportedVersion
    }
    return map
  }
}

// MARK: - Envelope Failure Mapping

extension AESGCMEnvelope {
  /// The credential seam's reading of the codec's failures. It lives here rather than on the codec
  /// because the runtime secret store maps the same failures differently, and one shared mapping
  /// would have to lose whichever distinction the other store depends on.
  func sealCredential(_ plaintext: Data, key: SymmetricKey) throws(CredentialStoreError) -> Data {
    do {
      return try seal(plaintext, key: key)
    } catch {
      throw .publicationFailed
    }
  }

  func openCredential(_ envelope: Data, key: SymmetricKey) throws(CredentialStoreError) -> Data {
    do {
      return try open(envelope, key: key)
    } catch AESGCMEnvelopeError.unsupportedVersion {
      // An unknown version is a build that cannot read this file — a different thing to tell an
      // owner than a tampered file, so it keeps its own remedy.
      throw .unsupportedVersion
    } catch {
      // A missing version byte or a failed tag: naming which would quote the decrypted token the
      // decoder chokes on, so both collapse into one plaintext-free refusal.
      throw .malformedStorage
    }
  }
}
