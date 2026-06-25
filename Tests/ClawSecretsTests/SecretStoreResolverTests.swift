import ClawCore
import Foundation
import Testing

@testable import ClawSecrets

@Suite struct SecretStoreResolverTests {
  private typealias EnvKey = EnvSecretStore.EnvKey

  private func makeStateRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("claw-resolve-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  @Test func picksEnvWhenNoEncryptedArtifacts() throws {
    // given — neither secrets.enc nor secret.key exists.
    let stateRoot = try makeStateRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    // when
    let resolution = SecretStoreResolver.resolve(
      stateRoot: stateRoot,
      environment: [EnvKey.botToken: "123:abc"],
      warn: { _ in }
    )

    // then
    #expect(resolution.backend == .env)
    #expect(try resolution.store.loadSecrets().telegramBotToken == "123:abc")
  }

  @Test func picksEncryptedWhenSealed() throws {
    // given
    let stateRoot = try makeStateRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    try EncryptedFileSecretStore.seal(
      Secrets(telegramBotToken: "123:abc", llmApiKey: nil),
      stateRoot: stateRoot
    )

    // when
    let resolution = SecretStoreResolver.resolve(
      stateRoot: stateRoot,
      environment: [:],
      warn: { _ in }
    )

    // then
    #expect(resolution.backend == .encrypted)
    #expect(try resolution.store.loadSecrets().telegramBotToken == "123:abc")
  }

  @Test func envelopeWithoutKeyFailsClosedNeverFallsBackToEnv() throws {
    // given — a partial encrypted setup: secrets.enc present, secret.key missing, env token set.
    let stateRoot = try makeStateRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    try EncryptedFileSecretStore.seal(
      Secrets(telegramBotToken: "123:abc", llmApiKey: nil),
      stateRoot: stateRoot
    )
    try FileManager.default.removeItem(
      at: stateRoot.appendingPathComponent(SecretFile.key)
    )

    // when — selection must require encrypted (it exists partially), not fall back to env.
    let resolution = SecretStoreResolver.resolve(
      stateRoot: stateRoot,
      environment: [EnvKey.botToken: "999:env-token"],
      warn: { _ in }
    )

    // then
    #expect(resolution.backend == .encrypted)
    #expect(throws: SecretStoreError.self) {
      try resolution.store.loadSecrets()  // never returns the env token
    }
  }

  @Test func danglingKeySymlinkForcesEncryptedNotEnv() throws {
    // given — secret.key is a BROKEN symlink (its target was never created) and an env token is set.
    // `FileManager.fileExists` follows symlinks and reports a broken one as absent (fail-open);
    // an `lstat`-based check sees the entry and must force the encrypted backend (fail-closed).
    let stateRoot = try makeStateRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    let keyURL = stateRoot.appendingPathComponent(SecretFile.key)
    let missingTarget = stateRoot.appendingPathComponent("gone.key")
    try FileManager.default.createSymbolicLink(at: keyURL, withDestinationURL: missingTarget)

    // when
    let resolution = SecretStoreResolver.resolve(
      stateRoot: stateRoot,
      environment: [EnvKey.botToken: "999:env-token"],
      warn: { _ in }
    )

    // then — a present (if broken) artifact entry requires encrypted; never the env token.
    #expect(resolution.backend == .encrypted)
    #expect(throws: SecretStoreError.self) {
      try resolution.store.loadSecrets()
    }
  }
}
