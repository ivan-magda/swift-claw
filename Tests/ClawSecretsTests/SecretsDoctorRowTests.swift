import ClawCore
import Foundation
import Testing

@testable import ClawSecrets

@Suite struct SecretsDoctorRowTests {
  private typealias EnvKey = EnvSecretStore.EnvKey

  private func makeStateRoot() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("claw-doctor-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  @Test func reportsEncryptedOkAfterDecrypt() throws {
    // given
    let stateRoot = try makeStateRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    try EncryptedFileSecretStore.seal(
      Secrets(telegramBotToken: "123:abc", llmApiKey: nil),
      stateRoot: stateRoot
    )

    // when — validates a real decrypt without booting the daemon.
    let row = SecretStoreResolver.doctorRow(stateRoot: stateRoot, environment: [:])

    // then
    #expect(row.ok)
    #expect(row.value == "backend=encrypted")
  }

  @Test func reportsEnvWarning() throws {
    // given
    let stateRoot = try makeStateRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    // when
    let row = SecretStoreResolver.doctorRow(
      stateRoot: stateRoot,
      environment: [EnvKey.botToken: "123:abc"]
    )

    // then
    #expect(row.ok)
    #expect(row.value == "backend=env (WARN: plaintext)")
  }

  @Test func reportsFailWhenEncryptedSetupIsBroken() throws {
    // given — secrets.enc present, key missing → decrypt fails.
    let stateRoot = try makeStateRoot()
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    try EncryptedFileSecretStore.seal(
      Secrets(telegramBotToken: "123:abc", llmApiKey: nil),
      stateRoot: stateRoot
    )
    try FileManager.default.removeItem(at: stateRoot.appendingPathComponent(SecretFile.key))

    // when
    let row = SecretStoreResolver.doctorRow(stateRoot: stateRoot, environment: [:])

    // then
    #expect(!row.ok)
    #expect(row.value.hasPrefix("FAIL:"))
  }
}
