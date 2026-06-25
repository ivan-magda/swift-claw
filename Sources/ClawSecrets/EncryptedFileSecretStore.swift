import ClawCore
import Crypto
import Foundation

#if canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

/// Encrypted-at-rest secrets over swift-crypto AES-GCM. The on-disk envelope is
/// `[1-byte version] + AES.GCM.SealedBox.combined` (12-byte random nonce ‖ ciphertext ‖ 16-byte tag);
/// the version byte is bound as **AEAD associated data**, so it can't be swapped without failing
/// authentication. The 256-bit key is 32 random bytes in `secret.key` (safe-opened in Task 03).
public struct EncryptedFileSecretStore: SecretStore {
  /// Current envelope version. Single-version today; bound as AAD so a future multi-version world
  /// dispatches on it AND authenticates it.
  static let envelopeVersion: UInt8 = 1
  static let keyByteCount = 32  // 256-bit symmetric key

  private let keyURL: URL
  private let envelopeURL: URL

  public init(stateRoot: URL) {
    keyURL = stateRoot.appendingPathComponent(SecretFile.key)
    envelopeURL = stateRoot.appendingPathComponent(SecretFile.envelope)
  }

  // MARK: - SecretStore

  public func loadSecrets() throws -> Secrets {
    let key = try Self.openKey(at: keyURL)

    guard
      let envelope = try? Data(contentsOf: envelopeURL),
      !envelope.isEmpty
    else {
      throw SecretStoreError.unreadable(SecretFile.envelope)
    }

    let plaintext = try Self.openEnvelope(envelope, key: key)

    return try Self.decode(plaintext)
  }

  // MARK: - Sealing (used by `clawd secrets seal`)

  /// Generates `secret.key` (0600, `O_EXCL`) if missing, then writes the versioned `secrets.enc`.
  public static func seal(_ secrets: Secrets, stateRoot: URL) throws {
    let keyURL = stateRoot.appendingPathComponent(SecretFile.key)
    let envelopeURL = stateRoot.appendingPathComponent(SecretFile.envelope)

    let key = try ensureKey(at: keyURL)

    let envelope = try sealEnvelope(encode(secrets), key: key)
    try envelope.write(to: envelopeURL, options: .atomic)
  }

  // MARK: - AES-GCM envelope

  static func sealEnvelope(_ plaintext: Data, key: SymmetricKey) throws -> Data {
    let associatedData = Data([envelopeVersion])
    let sealedBox = try AES.GCM.seal(plaintext, using: key, authenticating: associatedData)

    guard let combined = sealedBox.combined else {
      throw SecretStoreError.malformedEnvelope
    }

    return associatedData + combined
  }

  static func openEnvelope(_ envelope: Data, key: SymmetricKey) throws -> Data {
    guard let version = envelope.first, version == envelopeVersion else {
      throw SecretStoreError.malformedEnvelope
    }

    let associatedData = Data([version])

    do {
      let sealedBox = try AES.GCM.SealedBox(combined: Data(envelope.dropFirst()))
      return try AES.GCM.open(sealedBox, using: key, authenticating: associatedData)
    } catch {
      throw SecretStoreError.decryptionFailed
    }
  }

  // MARK: - Plaintext JSON map

  /// The JSON shape stored inside the encrypted envelope.
  private struct Payload: Codable {
    let telegramBotToken: String
    let llmApiKey: String?

    enum CodingKeys: String, CodingKey {
      case telegramBotToken = "telegram_bot_token"
      case llmApiKey = "llm_api_key"
    }
  }

  static func encode(_ secrets: Secrets) throws -> Data {
    let payload = Payload(
      telegramBotToken: secrets.telegramBotToken,
      llmApiKey: secrets.llmApiKey
    )
    return try JSONEncoder().encode(payload)
  }

  static func decode(_ data: Data) throws -> Secrets {
    guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
      throw SecretStoreError.malformedEnvelope
    }

    guard !payload.telegramBotToken.isEmpty else {
      throw SecretStoreError.missingTelegramToken
    }
    let apiKey = payload.llmApiKey.flatMap { $0.isEmpty ? nil : $0 }

    return Secrets(
      telegramBotToken: payload.telegramBotToken,
      llmApiKey: apiKey
    )
  }

  // MARK: - Key file

  static func ensureKey(at url: URL) throws -> SymmetricKey {
    if FileManager.default.fileExists(atPath: url.path) {
      return try openKey(at: url)
    }

    let key = SymmetricKey(size: .bits256)
    let keyData = key.withUnsafeBytes { Data($0) }
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)

    guard descriptor >= 0 else {
      throw SecretStoreError.keyFileInsecure(
        "create \(SecretFile.key): \(String(cString: strerror(errno)))"
      )
    }
    defer { close(descriptor) }

    try FileHandle(
      fileDescriptor: descriptor,
      closeOnDealloc: false
    )
    .write(contentsOf: keyData)

    return key
  }

  /// Minimal open for Task 02; Task 03 hardens it (O_NOFOLLOW + regular-file + owner + 0600).
  static func openKey(at url: URL) throws -> SymmetricKey {
    guard let data = try? Data(contentsOf: url), data.count == keyByteCount else {
      throw SecretStoreError.keyFileInsecure("key must be \(keyByteCount) bytes")
    }
    return SymmetricKey(data: data)
  }
}
