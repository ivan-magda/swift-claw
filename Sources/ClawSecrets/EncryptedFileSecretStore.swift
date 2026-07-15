import ClawCore
import Crypto
import Foundation

/// The artifacts one seal brought into existence, and the order they come back out in.
///
/// An entry is recorded only when this operation created it. A re-seal that merely replaces an
/// existing envelope records nothing, so rollback can never turn a healthy installation into the
/// partial state the resolver refuses to boot on.
struct CreatedRuntimeArtifacts {
  struct Step: Sendable, Equatable {
    let name: String
    let url: URL
    let identity: SecureFileIdentity
  }

  var key: Step?
  var envelope: Step?

  /// Envelope first, key second. The key alone is inert; an envelope whose key is already gone is
  /// unopenable ciphertext, so the window between the two unlinks should never be the one where
  /// the surviving artifact is the useless half.
  var removalPlan: [Step] {
    [envelope, key].compactMap { step in
      step
    }
  }

  func rollback(directory: URL) {
    for step in removalPlan {
      SecureFilePublisher.removeCreatedEntry(step.identity, at: step.url)
    }
    SecureFilePublisher.syncDirectory(directory)
  }
}

/// Encrypted-at-rest secrets over swift-crypto AES-GCM. The on-disk envelope is
/// `[1-byte version] + AES.GCM.SealedBox.combined` (12-byte random nonce ‖ ciphertext ‖ 16-byte tag);
/// the version byte is bound as **AEAD associated data**, so it can't be swapped without failing
/// authentication. The 256-bit key is 32 random bytes in `secret.key` (safe-opened by `openKey`).
public struct EncryptedFileSecretStore: SecretStore {
  /// Current envelope version. Single-version today; bound as AAD so a future multi-version world
  /// dispatches on it AND authenticates it.
  static let envelopeVersion: UInt8 = 1
  static let keyByteCount = 32  // 256-bit symmetric key
  /// Cap on the envelope before its plaintext is allocated.
  static let maximumEnvelopeByteCount = 256 * 1024

  static let keyReadPolicy = SecureFilePublisher.ReadPolicy(
    maximumByteCount: keyByteCount,
    requiredPermissionBits: SecureFilePublisher.ownerOnlyPermissions
  )
  static let envelopeReadPolicy = SecureFilePublisher.ReadPolicy(
    maximumByteCount: maximumEnvelopeByteCount,
    requiredPermissionBits: nil
  )

  private let paths: SecretStatePaths

  public init(stateRoot: URL) {
    paths = SecretStatePaths(stateRoot: stateRoot)
  }

  // MARK: - SecretStore

  public func loadSecrets() throws -> Secrets {
    try load()
  }

  /// The typed twin of `loadSecrets`. `SecretStore` cannot declare an error type, so this is where
  /// "only `SecretStoreError` leaves the seam" stops being a convention and becomes a signature —
  /// every POSIX and Crypto failure below is mapped rather than rethrown.
  func load() throws(SecretStoreError) -> Secrets {
    let key = try Self.openKey(at: paths.key)
    let envelope = try Self.readEnvelope(at: paths.runtimeEnvelope)
    return try Self.decode(Self.openEnvelope(envelope, key: key))
  }

  // MARK: - Sealing (used by `clawd secrets seal` and by the login transition)

  /// The one hardened seal operation: creates `secret.key` (0600) if it is missing, publishes
  /// `secrets.enc` through the crash-safe protocol, and proves the result really decrypts before
  /// reporting success. If any step fails, only the artifacts this call created are removed —
  /// envelope first, key second — so an interrupted transition leaves an environment-backed
  /// installation exactly as it found it. Returns the value read back from disk, not the one
  /// handed in.
  @discardableResult
  public static func seal(_ secrets: Secrets, stateRoot: URL) throws(SecretStoreError) -> Secrets {
    try seal(secrets, stateRoot: stateRoot, publisher: SecureFilePublisher())
  }

  @discardableResult
  static func seal(
    _ secrets: Secrets,
    stateRoot: URL,
    publisher: SecureFilePublisher
  ) throws(SecretStoreError) -> Secrets {
    let paths = SecretStatePaths(stateRoot: stateRoot)
    var created = CreatedRuntimeArtifacts()
    var sealed = false

    // Every exit below this line that is not the happy one unwinds, so no future step can be added
    // outside the rollback's reach.
    defer {
      if !sealed {
        created.rollback(directory: paths.directory)
      }
    }

    let plaintext = try encode(secrets)
    // `decode` normalizes an empty optional key away, so a `Secrets` carrying one can never come
    // back out of the envelope byte-identical. Comparing the read-back against the handed-in value
    // would then condemn — and roll back — a write that is in fact perfect. Compare against what
    // this plaintext actually decodes to, and reject a genuinely unusable input here rather than
    // after a key exists on disk.
    let expected = try decode(plaintext)

    let key = try ensureKey(at: paths.key, publisher: publisher, created: &created)
    try publishEnvelope(
      sealEnvelope(plaintext, key: key),
      paths: paths,
      publisher: publisher,
      created: &created
    )

    // Read back through the daemon's own load path: the seal is done when what is on disk decrypts
    // to what went in, not when the last syscall returned 0.
    let loaded = try EncryptedFileSecretStore(stateRoot: stateRoot).load()
    guard loaded == expected else {
      throw .decryptionFailed
    }

    sealed = true
    return loaded
  }
}

// MARK: - AES-GCM envelope

extension EncryptedFileSecretStore {
  static func sealEnvelope(_ plaintext: Data, key: SymmetricKey) throws(SecretStoreError) -> Data {
    let associatedData = Data([envelopeVersion])

    guard
      let sealedBox = try? AES.GCM.seal(plaintext, using: key, authenticating: associatedData),
      let combined = sealedBox.combined
    else {
      throw .publicationFailed("seal \(SecretStatePaths.runtimeEnvelopeName)")
    }

    return associatedData + combined
  }

  static func openEnvelope(_ envelope: Data, key: SymmetricKey) throws(SecretStoreError) -> Data {
    guard let version = envelope.first, version == envelopeVersion else {
      throw .malformedEnvelope
    }

    let associatedData = Data([version])

    guard
      let sealedBox = try? AES.GCM.SealedBox(combined: Data(envelope.dropFirst())),
      let plaintext = try? AES.GCM.open(sealedBox, using: key, authenticating: associatedData)
    else {
      throw .decryptionFailed
    }

    return plaintext
  }
}

// MARK: - Plaintext JSON map

private extension EncryptedFileSecretStore {
  /// The JSON shape stored inside the encrypted envelope.
  struct Payload: Codable {
    let telegramBotToken: String
    let llmApiKey: String?
    let searchApiKey: String?

    enum CodingKeys: String, CodingKey {
      case telegramBotToken = "telegram_bot_token"
      case llmApiKey = "llm_api_key"
      case searchApiKey = "search_api_key"
    }
  }
}

extension EncryptedFileSecretStore {
  static func encode(_ secrets: Secrets) throws(SecretStoreError) -> Data {
    let payload = Payload(
      telegramBotToken: secrets.telegramBotToken,
      llmApiKey: secrets.llmApiKey,
      searchApiKey: secrets.searchApiKey
    )

    guard let encoded = try? JSONEncoder().encode(payload) else {
      throw .publicationFailed("encode \(SecretStatePaths.runtimeEnvelopeName)")
    }
    return encoded
  }

  static func decode(_ data: Data) throws(SecretStoreError) -> Secrets {
    guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
      throw .malformedEnvelope
    }

    guard !payload.telegramBotToken.isEmpty else {
      throw .missingTelegramToken
    }
    let apiKey = payload.llmApiKey.flatMap { value in
      value.isEmpty ? nil : value
    }
    let searchKey = payload.searchApiKey.flatMap { value in
      value.isEmpty ? nil : value
    }

    return Secrets(
      telegramBotToken: payload.telegramBotToken,
      llmApiKey: apiKey,
      searchApiKey: searchKey
    )
  }
}

// MARK: - Key file

extension EncryptedFileSecretStore {
  /// Opens an existing key through the no-follow, regular-file, owner-uid, mode-0600 checks.
  static func openKey(at url: URL) throws(SecretStoreError) -> SymmetricKey {
    let data: Data
    do {
      data = try SecureFilePublisher.read(at: url, policy: keyReadPolicy)
    } catch {
      throw mapKeyError(error)
    }

    guard data.count == keyByteCount else {
      throw .keyFileInsecure("\(SecretStatePaths.keyName) must be \(keyByteCount) bytes")
    }
    return SymmetricKey(data: data)
  }

  /// Returns the key at `url`, minting one only if the name is free — and proving it was free by
  /// claiming it exclusively rather than by looking first.
  ///
  /// The exclusivity is not a nicety. A checked-then-replaced key lets two concurrent seals both
  /// see no key and both publish one; the second unlinks the first's inode, and the first's already
  /// published envelope becomes ciphertext nothing can open. That is unrecoverable, so the loser of
  /// the race must lose at the kernel, before any key of its own exists on disk.
  static func ensureKey(
    at url: URL,
    publisher: SecureFilePublisher,
    created: inout CreatedRuntimeArtifacts
  ) throws(SecretStoreError) -> SymmetricKey {
    let key = SymmetricKey(size: .bits256)
    let outcome: SecureFilePublisher.PublicationOutcome
    do {
      outcome = try publisher.publish(
        key.withUnsafeBytes { bytes in
          Data(bytes)
        },
        to: url,
        mode: .exclusive
      )
    } catch SecureFileError.alreadyExists {
      // The name was already taken — by an older seal, or by whoever won this race. Their key is the
      // one any envelope beside it is sealed under; ours was never linked and simply evaporates.
      return try openKey(at: url)
    } catch {
      throw mapKeyError(error)
    }

    created.key = CreatedRuntimeArtifacts.Step(
      name: SecretStatePaths.keyName,
      url: url,
      identity: outcome.identity
    )

    guard !outcome.isCommitUncertain else {
      throw .publicationFailed(uncertainCommitGuidance(SecretStatePaths.keyName))
    }
    return key
  }
}

// MARK: - Envelope file

extension EncryptedFileSecretStore {
  static func readEnvelope(at url: URL) throws(SecretStoreError) -> Data {
    let bytes: Data
    do {
      bytes = try SecureFilePublisher.read(at: url, policy: envelopeReadPolicy)
    } catch {
      throw mapEnvelopeError(error)
    }

    guard !bytes.isEmpty else {
      throw .unreadable(SecretStatePaths.runtimeEnvelopeName)
    }
    return bytes
  }

  static func publishEnvelope(
    _ envelope: Data,
    paths: SecretStatePaths,
    publisher: SecureFilePublisher,
    created: inout CreatedRuntimeArtifacts
  ) throws(SecretStoreError) {
    let url = paths.runtimeEnvelope
    let existed = SecureFilePublisher.entryExists(at: url)

    let outcome: SecureFilePublisher.PublicationOutcome
    do {
      outcome = try publisher.publish(envelope, to: url)
    } catch {
      // Nothing was renamed, so whatever the owner had is still whole.
      throw mapEnvelopeError(error)
    }

    if !existed {
      created.envelope = CreatedRuntimeArtifacts.Step(
        name: SecretStatePaths.runtimeEnvelopeName,
        url: url,
        identity: outcome.identity
      )
    }

    guard !outcome.isCommitUncertain else {
      throw .publicationFailed(uncertainCommitGuidance(SecretStatePaths.runtimeEnvelopeName))
    }
  }
}

// MARK: - Seam error mapping

private extension EncryptedFileSecretStore {
  /// The runtime-secret seam does not distinguish an uncertain commit from an outright failure the
  /// way the credential store must: no caller here can retry a half-durable seal into safety, and
  /// the owner's remedy for both is the same rerun.
  static func uncertainCommitGuidance(_ name: String) -> String {
    "\(name) was renamed into place but not proven durable — rerun `clawd secrets seal`"
  }

  /// `.alreadyExists` is the one outcome neither map should ever be handed: `ensureKey` answers it
  /// by opening the incumbent key, and the envelope is published to be replaced. Mapping it to a
  /// publication failure keeps that assumption from turning a future exclusive caller's silence
  /// into a wrong diagnosis.
  static func mapKeyError(_ error: SecureFileError) -> SecretStoreError {
    switch error {
    case .insecure(let reason), .unreadable(let reason):
      return .keyFileInsecure(reason)
    case .oversized:
      return .keyFileInsecure("\(SecretStatePaths.keyName) must be \(keyByteCount) bytes")
    case .publicationFailed(let reason):
      return .publicationFailed(reason)
    case .alreadyExists(let name):
      return .publicationFailed("\(name) already exists")
    }
  }

  static func mapEnvelopeError(_ error: SecureFileError) -> SecretStoreError {
    switch error {
    case .insecure(let reason), .unreadable(let reason):
      return .unreadable(reason)
    case .oversized:
      return .malformedEnvelope
    case .publicationFailed(let reason):
      return .publicationFailed(reason)
    case .alreadyExists(let name):
      return .publicationFailed("\(name) already exists")
    }
  }
}
