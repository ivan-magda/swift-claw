import ClawCore
import ClawTestSupport
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

  // Owner mismatch and file-type are validated through the pure policy seam, because there is no
  // portable way to chown to a foreign uid unprivileged. (Automates acceptance #5's "wrong-owner".)
  @Test(arguments: [
    (
      name: "non-regular", isRegular: false, perms: UInt32(0o600), ownerDelta: UInt32(0),
      throws: true
    ),
    (
      name: "world-readable", isRegular: true, perms: UInt32(0o644), ownerDelta: UInt32(0),
      throws: true
    ),
    (
      name: "wrong-owner", isRegular: true, perms: UInt32(0o600), ownerDelta: UInt32(1),
      throws: true
    ),
    (
      name: "regular-0600-owned", isRegular: true, perms: UInt32(0o600), ownerDelta: UInt32(0),
      throws: false
    ),
  ]) func keyMetadataPolicy(
    name: String,
    isRegular: Bool,
    perms: UInt32,
    ownerDelta: UInt32,
    throws expectThrow: Bool
  ) {
    // given
    let metadata = EncryptedFileSecretStore.KeyFileMetadata(
      isRegularFile: isRegular,
      permissionBits: perms,
      ownerUID: getuid() &+ ownerDelta
    )

    // when / then
    if expectThrow {
      #expect(throws: SecretStoreError.self) {
        try EncryptedFileSecretStore.validateKeyMetadata(metadata, expectedUID: getuid())
      }
    } else {
      #expect(throws: Never.self) {
        try EncryptedFileSecretStore.validateKeyMetadata(metadata, expectedUID: getuid())
      }
    }
  }
}
