import ClawCore
import ClawTestSupport
import Crypto
import Foundation
import Testing

@testable import ClawSecrets

#if canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

@Suite struct KeyFileSecurityTests {
  private func writeKey(at url: URL, mode: Int) throws {
    try Data(repeating: 0xAB, count: EncryptedFileSecretStore.keyByteCount).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
  }

  @Test func acceptsRegularOwned0600Key() throws {
    // given
    let stateRoot = try makeTemporaryRoot(prefix: "claw-keysec")
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    let keyURL = stateRoot.appendingPathComponent(SecretFile.key)
    try writeKey(at: keyURL, mode: 0o600)

    // when / then — a well-formed key opens without throwing.
    #expect(throws: Never.self) {
      _ = try EncryptedFileSecretStore.openKey(at: keyURL)
    }
  }

  @Test func rejectsWorldReadableKey() throws {
    // given
    let stateRoot = try makeTemporaryRoot(prefix: "claw-keysec")
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    let keyURL = stateRoot.appendingPathComponent(SecretFile.key)
    try writeKey(at: keyURL, mode: 0o644)

    // when / then
    #expect(throws: SecretStoreError.self) {
      _ = try EncryptedFileSecretStore.openKey(at: keyURL)
    }
  }

  @Test func rejectsSymlinkedKey() throws {
    // given — a symlink whose target is a valid 0600 key; O_NOFOLLOW must still refuse it.
    let stateRoot = try makeTemporaryRoot(prefix: "claw-keysec")
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    let realKey = stateRoot.appendingPathComponent("real.key")
    try writeKey(at: realKey, mode: 0o600)
    let linkURL = stateRoot.appendingPathComponent(SecretFile.key)
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: realKey)

    // when / then
    #expect(throws: SecretStoreError.self) {
      _ = try EncryptedFileSecretStore.openKey(at: linkURL)
    }
  }

  @Test func rejectsWrongLengthKey() throws {
    // given
    let stateRoot = try makeTemporaryRoot(prefix: "claw-keysec")
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    let keyURL = stateRoot.appendingPathComponent(SecretFile.key)
    try Data(repeating: 0xAB, count: 16).write(to: keyURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)

    // when / then
    #expect(throws: SecretStoreError.self) {
      _ = try EncryptedFileSecretStore.openKey(at: keyURL)
    }
  }

  @Test func rejectsNonRegularKey() throws {
    // given — a directory standing in for secret.key; open succeeds but fstat reports a non-regular
    // file, so the metadata policy must reject it before any read.
    let stateRoot = try makeTemporaryRoot(prefix: "claw-keysec")
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    let keyURL = stateRoot.appendingPathComponent(SecretFile.key)
    try FileManager.default.createDirectory(at: keyURL, withIntermediateDirectories: false)

    // when / then
    #expect(throws: SecretStoreError.self) {
      _ = try EncryptedFileSecretStore.openKey(at: keyURL)
    }
  }

  @Test func rejectsAnOversizedKey() throws {
    // given — the key policy caps the read at the key length, so a padded file is refused rather
    // than truncated into a plausible-looking key.
    let stateRoot = try makeTemporaryRoot(prefix: "claw-keysec")
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    let keyURL = stateRoot.appendingPathComponent(SecretFile.key)
    try Data(repeating: 0xAB, count: EncryptedFileSecretStore.keyByteCount * 2).write(to: keyURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)

    // when / then
    #expect(throws: SecretStoreError.self) {
      _ = try EncryptedFileSecretStore.openKey(at: keyURL)
    }
  }

  // MARK: - Exclusive creation

  @Test func ensureKeyReturnsAnExistingKeyRatherThanMintingOverIt() throws {
    // given
    let stateRoot = try makeTemporaryRoot(prefix: "claw-keysec")
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    let keyURL = stateRoot.appendingPathComponent(SecretFile.key)
    try writeKey(at: keyURL, mode: 0o600)
    let before = try #require(SecureFilePublisher.facts(ofEntryAt: keyURL))

    // when
    var created = CreatedRuntimeArtifacts()
    let key = try EncryptedFileSecretStore.ensureKey(
      at: keyURL,
      publisher: SecureFilePublisher(),
      created: &created
    )

    // then — the incumbent inode survives and its bytes are what came back, so an envelope already
    // sealed under it stays openable.
    let after = try #require(SecureFilePublisher.facts(ofEntryAt: keyURL))
    #expect(after.identity == before.identity)
    #expect(
      key
        == SymmetricKey(
          data: Data(repeating: 0xAB, count: EncryptedFileSecretStore.keyByteCount)
        )
    )
    // Nothing was created, so rollback has nothing it could unlink.
    #expect(created.key == nil)
  }

  @Test func ensureKeyRefusesToMintOverAnUnreadableIncumbent() throws {
    // given — a key that exists but fails the metadata policy.
    let stateRoot = try makeTemporaryRoot(prefix: "claw-keysec")
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    let keyURL = stateRoot.appendingPathComponent(SecretFile.key)
    try writeKey(at: keyURL, mode: 0o644)
    let before = try #require(SecureFilePublisher.facts(ofEntryAt: keyURL))

    // when / then — the answer to a key it cannot open is to stop, never to replace it: overwriting
    // would strand every envelope already sealed under it.
    var created = CreatedRuntimeArtifacts()
    #expect(throws: SecretStoreError.self) {
      _ = try EncryptedFileSecretStore.ensureKey(
        at: keyURL,
        publisher: SecureFilePublisher(),
        created: &created
      )
    }
    let after = try #require(SecureFilePublisher.facts(ofEntryAt: keyURL))
    #expect(after.identity == before.identity)
    #expect(created.key == nil)
  }

  // Owner mismatch and file-type are validated through the pure policy seam that
  // `SecureFilePublisherTests` table-tests, because there is no portable way to chown to a foreign
  // uid unprivileged. (Automates acceptance #5's "wrong-owner".)
}
