import ClawCore
import Crypto
import Foundation

/// The provider-keyed OAuth map, encrypted at rest under the same 256-bit `secret.key` the runtime
/// envelope uses. The on-disk envelope is `[1-byte version] + AES.GCM.SealedBox.combined`, and the
/// associated data names this file's purpose as well as its version — which is what keeps the two
/// envelopes in the state root from being interchangeable despite sharing a key.
///
/// It takes a state root and nothing else. Every path it touches comes from `SecretStatePaths`,
/// which exposes fixed names only, so there is no argument that could aim this store at another
/// vendor's credential file.
public struct EncryptedLLMCredentialStore: LLMCredentialStore {
  /// The version this store writes. Its AAD labels the credential file's purpose alongside this byte.
  static let envelopeVersion: UInt8 = 1
  /// Current version of the JSON map inside the envelope. It moves independently of the envelope's:
  /// a new record shape does not imply new cryptography.
  static let mapVersion = 1
  static let maximumEnvelopeByteCount = AESGCMEnvelope.maximumByteCount

  /// The shared codec bound to this store's version and its purpose-labeled AAD.
  static let envelopeCodec = AESGCMEnvelope(
    version: envelopeVersion,
    associatedData: associatedData(version: envelopeVersion)
  )

  /// Unlike the runtime envelope, whose 0644 predates the publication protocol and must keep
  /// opening, nothing anywhere has ever written this file except through the protocol below. It is
  /// new, so it can demand the mode a secret deserves.
  static let envelopeReadPolicy = SecureFilePublisher.ReadPolicy(
    maximumByteCount: maximumEnvelopeByteCount,
    requiredPermissionBits: SecureFilePublisher.ownerOnlyPermissions
  )

  private let paths: SecretStatePaths
  private let publisher: SecureFilePublisher
  /// Serializes read-modify-write cycles that share this one store instance. Two interleaved saves
  /// would each read the same map and publish their own record, dropping the other's — silent
  /// credential loss for a provider map. The lock lives on the instance, so it guards only concurrent
  /// callers of the same store; safety across separately constructed stores against one state root is
  /// owned elsewhere — by the daemon's credential actor and by the instance lock the mutating CLI
  /// commands hold — not here.
  private let mutation = NSLock()

  public init(stateRoot: URL) {
    self.init(stateRoot: stateRoot, publisher: SecureFilePublisher())
  }

  init(stateRoot: URL, publisher: SecureFilePublisher) {
    paths = SecretStatePaths(stateRoot: stateRoot)
    self.publisher = publisher
  }

  // MARK: - LLMCredentialStore

  /// Takes no lock. The commit is a rename, so a reader sees the whole old map or the whole new one
  /// and never a torn one; making readers queue behind a writer's fsync would buy nothing.
  public func load(
    providerID: LLMProviderID
  ) throws(LLMCredentialStoreError) -> StoredOAuthCredential? {
    guard SecureFilePublisher.entryExists(at: paths.credentialEnvelope) else {
      return nil
    }
    return try loadMap(key: try openKey())?.providers[providerID]
  }

  public func save(
    _ credential: StoredOAuthCredential,
    providerID: LLMProviderID
  ) throws(LLMCredentialStoreError) {
    try mutate { map in
      map.providers[providerID] = credential
      return true
    }
  }

  /// Removing the last record rewrites a valid empty map rather than unlinking the file: an absent
  /// envelope and an empty one read the same to this store, but only one of them proves logout ran
  /// rather than something having eaten the file.
  public func delete(providerID: LLMProviderID) throws(LLMCredentialStoreError) {
    try mutate { map in
      map.providers.removeValue(forKey: providerID) != nil
    }
  }
}

// MARK: - Read-Modify-Write

private extension EncryptedLLMCredentialStore {
  /// One serialized cycle: open the key, read the whole map, let `body` change it, publish the
  /// whole map back. `body` reports whether anything actually changed, so an already-absent record
  /// costs no rewrite — and cannot reseal an unchanged map under a fresh nonce.
  ///
  /// The lock is held across the entire cycle and never across an `await`: every step is a bounded
  /// synchronous syscall, so there is no suspension point at which a second mutation could interleave.
  func mutate(_ body: (inout CredentialMap) -> Bool) throws(LLMCredentialStoreError) {
    mutation.lock()
    defer { mutation.unlock() }

    let key = try openKey()
    // A map that cannot be read is not overwritten. Preserving unrelated records is an invariant,
    // and blindly republishing over ciphertext this build cannot open would destroy records it was
    // never able to see.
    var map = try loadMap(key: key) ?? CredentialMap()
    guard body(&map) else {
      return
    }
    try publish(map, key: key)
  }
}

// MARK: - Publication

extension EncryptedLLMCredentialStore {
  func publish(_ map: CredentialMap, key: SymmetricKey) throws(LLMCredentialStoreError) {
    let outcome = try publishEnvelope(map, key: key)
    guard outcome.isCommitUncertain else {
      return
    }
    try recoverUncertainCommit(map, key: key)
  }

  /// The uncertain-commit contract. The bytes are readable at the target, but the rename that put
  /// them there is not proven to survive a crash — and a caller told "saved" will act on that:
  /// it will use the rotated credential, and the vendor has already invalidated the one the file
  /// would revert to. So the intended bytes being visible is never the answer here; a proven fsync
  /// is. Returning means durable, or this throws.
  func recoverUncertainCommit(
    _ intended: CredentialMap,
    key: SymmetricKey
  ) throws(LLMCredentialStoreError) {
    if readableMap(key: key) == intended {
      // The rename took and the bytes are the ones meant to be there, so only the parent
      // directory's durability is outstanding. Retry precisely that.
      guard
        publisher.syncDirectory(
          paths.directory,
          forEntry: SecretStatePaths.credentialEnvelopeName
        )
      else {
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
}

private extension EncryptedLLMCredentialStore {
  func publishEnvelope(
    _ map: CredentialMap,
    key: SymmetricKey
  ) throws(LLMCredentialStoreError) -> SecureFilePublisher.PublicationOutcome {
    let envelope = try Self.sealEnvelope(try Self.encode(map), key: key)
    do {
      return try publisher.publish(envelope, to: paths.credentialEnvelope, mode: .replace)
    } catch {
      // Throwing from `publish` means the name was never claimed, so whatever the owner had is
      // still whole and the caller may retry as though nothing happened.
      throw Self.mapEnvelopeError(error)
    }
  }

  /// The map at the path, or nil if there is nothing there this build can read. Only recovery may
  /// use this: it is deciding whether the intended bytes arrived, and anything unreadable is by
  /// definition not them. Every other caller must see the typed refusal instead.
  func readableMap(key: SymmetricKey) -> CredentialMap? {
    guard let map = try? loadMap(key: key) else {
      return nil
    }
    return map
  }
}

// MARK: - Plaintext Provider Map

extension EncryptedLLMCredentialStore {
  /// The JSON inside the envelope. `providers` is a dictionary rather than a list so "at most one
  /// record per provider" is the type's problem rather than every caller's, and it encodes as a
  /// JSON object because `LLMProviderID` is `CodingKeyRepresentable`.
  struct CredentialMap: Codable, Equatable {
    var version: Int
    var providers: [LLMProviderID: StoredOAuthCredential]

    /// `version` has no default on the property itself: Codable synthesis would not honour one, and
    /// a map that reached disk without a version is one this build must refuse rather than assume.
    init(
      version: Int = EncryptedLLMCredentialStore.mapVersion,
      providers: [LLMProviderID: StoredOAuthCredential] = [:]
    ) {
      self.version = version
      self.providers = providers
    }
  }

  /// `.sortedKeys` is load-bearing rather than cosmetic. `Dictionary` iterates in an order derived
  /// from a per-process hash seed, so without it the same map would seal to different plaintext in
  /// every process — and it only reaches a keyed container, which is why the key type's
  /// `CodingKeyRepresentable` conformance is what this depends on.
  static func encode(_ map: CredentialMap) throws(LLMCredentialStoreError) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let encoded = try? encoder.encode(map) else {
      throw .publicationFailed
    }
    return encoded
  }

  static func decode(_ plaintext: Data) throws(LLMCredentialStoreError) -> CredentialMap {
    // The decoder's error quotes the bytes it choked on — which here are a decrypted refresh token.
    // Discarding it entirely, rather than mapping it, is what keeps plaintext off this seam.
    guard let map = try? JSONDecoder().decode(CredentialMap.self, from: plaintext) else {
      throw .malformedStorage
    }
    guard map.version == mapVersion else {
      throw .unsupportedVersion
    }
    return map
  }
}

// MARK: - AES-GCM Envelope

extension EncryptedLLMCredentialStore {
  /// The AEAD associated data: this file's purpose and its version, derived from the version rather
  /// than written twice so the two can never drift apart. `secrets.enc` authenticates a bare version
  /// byte under the same key, so this label is the whole reason its ciphertext moved to this name
  /// fails the tag check instead of opening as a credential map.
  static func associatedData(version: UInt8) -> Data {
    Data("swift-claw:llm-credentials:v\(version)".utf8)
  }

  static func sealEnvelope(
    _ plaintext: Data,
    key: SymmetricKey
  ) throws(LLMCredentialStoreError) -> Data {
    do {
      return try envelopeCodec.seal(plaintext, key: key)
    } catch {
      throw .publicationFailed
    }
  }

  static func openEnvelope(
    _ envelope: Data,
    key: SymmetricKey
  ) throws(LLMCredentialStoreError) -> Data {
    do {
      return try envelopeCodec.open(envelope, key: key)
    } catch AESGCMEnvelopeError.unsupportedVersion {
      // An unknown version is a build that cannot read this file — a different thing to tell an owner
      // than a tampered file, so it keeps its own remedy.
      throw .unsupportedVersion
    } catch {
      // A missing version byte or a failed tag: naming which would quote the decrypted refresh token
      // the decoder chokes on, so both collapse into one plaintext-free refusal.
      throw .malformedStorage
    }
  }
}

// MARK: - Key And Envelope Files

private extension EncryptedLLMCredentialStore {
  /// The credential map is sealed under the runtime key, so a state root without one has nothing to
  /// open with. "Log in first" and "your key's mode or owner is wrong" are separate problems with
  /// separate remedies, and the shared key-open path collapses both into one refusal — so the
  /// distinction is drawn here, from whether anything stands at the path at all.
  func openKey() throws(LLMCredentialStoreError) -> SymmetricKey {
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

  func loadMap(key: SymmetricKey) throws(LLMCredentialStoreError) -> CredentialMap? {
    guard SecureFilePublisher.entryExists(at: paths.credentialEnvelope) else {
      return nil
    }

    let envelope: Data
    do {
      envelope = try SecureFilePublisher.read(
        at: paths.credentialEnvelope,
        policy: Self.envelopeReadPolicy
      )
    } catch {
      throw Self.mapEnvelopeError(error)
    }
    return try Self.decode(try Self.openEnvelope(envelope, key: key))
  }
}

// MARK: - Seam Error Mapping

private extension EncryptedLLMCredentialStore {
  static func mapEnvelopeError(_ error: SecureFileError) -> LLMCredentialStoreError {
    switch error {
    case .insecure, .unreadable:
      // Reached only once something has been seen standing at the path, so a no-follow open that
      // fails is the protocol refusing a planted symlink — not an absent file.
      return .insecureStorage
    case .oversized:
      return .oversizedStorage
    case .publicationFailed, .alreadyExists:
      // `.alreadyExists` is unreachable: this file is published to be replaced. Folding it in
      // rather than assuming it away keeps a future exclusive caller from being misdiagnosed.
      return .publicationFailed
    }
  }
}
