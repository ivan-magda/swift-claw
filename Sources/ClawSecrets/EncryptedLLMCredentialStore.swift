import ClawCore
import Crypto
import Foundation

/// The provider-keyed OAuth map, encrypted at rest under the same 256-bit `secret.key` the runtime
/// envelope uses. The on-disk envelope is `[1-byte version] + AES.GCM.SealedBox.combined`, and the
/// associated data names this file's purpose as well as its version — which is what keeps the
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
  static let maximumEnvelopeByteCount = SealedCredentialFile<CredentialMap>.maximumEnvelopeByteCount

  /// The shared codec bound to this store's version and its purpose-labeled AAD.
  static let envelopeCodec = AESGCMEnvelope(
    version: envelopeVersion,
    associatedData: associatedData(version: envelopeVersion)
  )

  static let envelopeReadPolicy = SealedCredentialFile<CredentialMap>.readPolicy

  private let file: SealedCredentialFile<CredentialMap>

  public init(stateRoot: URL) {
    self.init(stateRoot: stateRoot, publisher: SecureFilePublisher())
  }

  init(stateRoot: URL, publisher: SecureFilePublisher) {
    file = SealedCredentialFile(
      stateRoot: stateRoot,
      entry: .llmCredentials,
      codec: Self.envelopeCodec,
      publisher: publisher
    )
  }

  // MARK: - LLMCredentialStore

  public func load(
    providerID: LLMProviderID
  ) throws(LLMCredentialStoreError) -> StoredOAuthCredential? {
    try file.load()?.providers[providerID]
  }

  public func save(
    _ credential: StoredOAuthCredential,
    providerID: LLMProviderID
  ) throws(LLMCredentialStoreError) {
    try file.mutate { map in
      map.providers[providerID] = credential
      return true
    }
  }

  /// Removing the last record rewrites a valid empty map rather than unlinking the file: an absent
  /// envelope and an empty one read the same to this store, but only one of them proves logout ran
  /// rather than something having eaten the file.
  public func delete(providerID: LLMProviderID) throws(LLMCredentialStoreError) {
    try file.mutate { map in
      map.providers.removeValue(forKey: providerID) != nil
    }
  }
}

// MARK: - Publication

extension EncryptedLLMCredentialStore {
  /// The uncertain-commit contract, exposed at this seam because it is this store's promise that a
  /// caller told "saved" holds a durable credential.
  func recoverUncertainCommit(
    _ intended: CredentialMap,
    key: SymmetricKey
  ) throws(LLMCredentialStoreError) {
    try file.recoverUncertainCommit(intended, key: key)
  }
}

// MARK: - Plaintext Provider Map

extension EncryptedLLMCredentialStore {
  /// The JSON inside the envelope. `providers` is a dictionary rather than a list so "at most one
  /// record per provider" is the type's problem rather than every caller's, and it encodes as a
  /// JSON object because `LLMProviderID` is `CodingKeyRepresentable`.
  struct CredentialMap: SealedCredentialMap {
    static let currentVersion = EncryptedLLMCredentialStore.mapVersion
    static let empty = CredentialMap()

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

  static func encode(_ map: CredentialMap) throws(LLMCredentialStoreError) -> Data {
    try SealedCredentialFile<CredentialMap>.encode(map)
  }

  static func decode(_ plaintext: Data) throws(LLMCredentialStoreError) -> CredentialMap {
    try SealedCredentialFile<CredentialMap>.decode(plaintext)
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
    try envelopeCodec.sealCredential(plaintext, key: key)
  }

  static func openEnvelope(
    _ envelope: Data,
    key: SymmetricKey
  ) throws(LLMCredentialStoreError) -> Data {
    try envelopeCodec.openCredential(envelope, key: key)
  }
}
