import ClawCore
import ClawTestSupport
import Crypto
import Foundation
import Testing

@testable import ClawSecrets

@Suite struct EncryptedFileSecretStoreTests {
  @Test func sealThenLoadRoundTrips() throws {
    // given
    let stateRoot = try makeTemporaryRoot(prefix: "claw-secrets")
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    let original = Secrets(telegramBotToken: "123:abc", llmApiKey: "sk-secret")

    // when
    try EncryptedFileSecretStore.seal(original, stateRoot: stateRoot)
    let loaded = try EncryptedFileSecretStore(stateRoot: stateRoot).loadSecrets()

    // then
    #expect(loaded == original)
  }

  @Test func anEnvelopeWrittenBeforeThePublicationProtocolStillDecrypts() throws {
    // given — a byte-for-byte reconstruction of what an installation sealed by the previous
    // implementation has on disk: a version-1 envelope authenticated under AAD [1], written by
    // Foundation's atomic write (which creates 0644), beside a 0600 key. Nothing about the new
    // read path may lock that owner out of their own secrets.
    //
    // The version byte and the AAD are frozen literals, never `envelopeVersion`: what is on those
    // owners' disks is the number 1, and a fixture that tracked the constant would follow a future
    // bump straight past the breakage it exists to catch.
    let stateRoot = try makeTemporaryRoot(prefix: "claw-secrets")
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    let keyData = Data(repeating: 0x5A, count: EncryptedFileSecretStore.keyByteCount)
    let keyURL = stateRoot.appendingPathComponent(SecretFile.key)
    try keyData.write(to: keyURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)

    let payload = try JSONEncoder().encode([
      "telegram_bot_token": "123:legacy",
      "llm_api_key": "sk-legacy",
      "search_api_key": "search-legacy",
    ])
    let sealed = try AES.GCM.seal(
      payload,
      using: SymmetricKey(data: keyData),
      authenticating: Data([1])
    )
    let envelopeURL = stateRoot.appendingPathComponent(SecretFile.envelope)
    let combined = try #require(sealed.combined)
    try (Data([1]) + combined).write(to: envelopeURL, options: .atomic)

    // when
    let loaded = try EncryptedFileSecretStore(stateRoot: stateRoot).loadSecrets()

    // then
    #expect(
      loaded
        == Secrets(
          telegramBotToken: "123:legacy",
          llmApiKey: "sk-legacy",
          searchApiKey: "search-legacy"
        )
    )
  }

  @Test func sealPublishesTheEnvelopeOwnerOnly() throws {
    // given
    let stateRoot = try makeTemporaryRoot(prefix: "claw-secrets")
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    // when — going forward the envelope is published owner-only even though the reader tolerates
    // the 0644 that Foundation's atomic write left on older installations.
    try EncryptedFileSecretStore.seal(
      Secrets(telegramBotToken: "123:abc", llmApiKey: nil),
      stateRoot: stateRoot
    )

    // then
    for name in [SecretFile.key, SecretFile.envelope] {
      let attributes = try FileManager.default.attributesOfItem(
        atPath: stateRoot.appendingPathComponent(name).path
      )
      #expect(attributes[.posixPermissions] as? NSNumber == 0o600)
    }
  }

  @Test func sealedEnvelopeContainsNoPlaintextToken() throws {
    // given
    let stateRoot = try makeTemporaryRoot(prefix: "claw-secrets")
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    let token = "123:super-secret-token"

    // when
    try EncryptedFileSecretStore.seal(
      Secrets(telegramBotToken: token, llmApiKey: nil),
      stateRoot: stateRoot
    )
    let envelope = try Data(
      contentsOf: stateRoot.appendingPathComponent(SecretFile.envelope)
    )

    // then — the token's bytes never appear in the ciphertext at rest.
    #expect(envelope.range(of: Data(token.utf8)) == nil)
  }

  @Test func tamperedCiphertextFailsClosed() throws {
    // given
    let stateRoot = try makeTemporaryRoot(prefix: "claw-secrets")
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    try EncryptedFileSecretStore.seal(
      Secrets(telegramBotToken: "123:abc", llmApiKey: nil),
      stateRoot: stateRoot
    )
    let envelopeURL = stateRoot.appendingPathComponent(SecretFile.envelope)
    var bytes = try Data(contentsOf: envelopeURL)

    // when — flip a byte deep in the ciphertext (past the version + nonce).
    bytes[bytes.count - 1] ^= 0xFF
    try bytes.write(to: envelopeURL)

    // then
    #expect(throws: SecretStoreError.self) {
      try EncryptedFileSecretStore(stateRoot: stateRoot).loadSecrets()
    }
  }

  @Test func tamperedVersionByteFailsClosed() throws {
    // given
    let stateRoot = try makeTemporaryRoot(prefix: "claw-secrets")
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    try EncryptedFileSecretStore.seal(
      Secrets(telegramBotToken: "123:abc", llmApiKey: nil),
      stateRoot: stateRoot
    )
    let envelopeURL = stateRoot.appendingPathComponent(SecretFile.envelope)
    var bytes = try Data(contentsOf: envelopeURL)

    // when — set the version byte to an UNSUPPORTED value.
    bytes[0] = 0x99
    try bytes.write(to: envelopeURL)

    // then — the version guard rejects an unknown version before AES-GCM (fail-closed dispatch).
    #expect(throws: SecretStoreError.self) {
      try EncryptedFileSecretStore(stateRoot: stateRoot).loadSecrets()
    }
  }

  @Test func envelopeAuthenticatedUnderDifferentVersionFailsAuthentication() throws {
    // given — a valid on-disk version byte (1, supported) but ciphertext authenticated under a
    // DIFFERENT associated-data byte. This proves the version byte is bound as AEAD AAD: the reader
    // passes the version guard, then authentication fails because the AAD it uses ([1]) differs
    // from the AAD the box was sealed with ([2]). Built by hand with a key we control.
    let stateRoot = try makeTemporaryRoot(prefix: "claw-secrets")
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    let keyData = Data(repeating: 0x11, count: EncryptedFileSecretStore.keyByteCount)
    let keyURL = stateRoot.appendingPathComponent(SecretFile.key)
    try keyData.write(to: keyURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)

    let payload = try JSONEncoder().encode(["telegram_bot_token": "123:abc"])
    let sealed = try AES.GCM.seal(
      payload,
      using: SymmetricKey(data: keyData),
      authenticating: Data([2])  // AAD = version 2 …
    )
    let combined = try #require(sealed.combined)
    let envelope = Data([1]) + combined  // … but the on-disk version byte claims 1
    try envelope.write(to: stateRoot.appendingPathComponent(SecretFile.envelope))

    // then
    #expect(throws: SecretStoreError.self) {
      try EncryptedFileSecretStore(stateRoot: stateRoot).loadSecrets()
    }
  }
}
