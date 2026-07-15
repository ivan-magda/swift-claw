import ClawCore
import Foundation
import Testing

@testable import ClawSecrets

@Suite struct EnvSecretStoreTests {
  private typealias EnvKey = EnvSecretStore.EnvKey

  /// A concurrency-safe test spy for the `@Sendable` warn closure. A `@Sendable` closure may not
  /// capture-and-mutate a local `var` under Swift 6 strict concurrency, so the recorder is a
  /// lock-guarded reference type the closure captures by reference.
  private final class WarningSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func record(_ message: String) {
      lock.lock()
      defer { lock.unlock() }
      messages.append(message)
    }

    var recorded: [String] {
      lock.lock()
      defer { lock.unlock() }
      return messages
    }
  }

  @Test func loadsTokenAndKeyFromEnvironment() throws {
    // given
    let store = EnvSecretStore(
      environment: [EnvKey.botToken: "123:abc", EnvKey.llmApiKey: "sk-test"],
      warn: { _ in }
    )

    // when
    let secrets = try store.loadSecrets()

    // then
    #expect(secrets.telegramBotToken == "123:abc")
    #expect(secrets.llmApiKey == "sk-test")
  }

  @Test func missingTokenFailsClosed() {
    // given
    let store = EnvSecretStore(environment: [:], warn: { _ in })

    // when / then
    #expect(throws: SecretStoreError.missingTelegramToken) {
      try store.loadSecrets()
    }
  }

  @Test func blankApiKeyBecomesNil() throws {
    // given
    let store = EnvSecretStore(
      environment: [EnvKey.botToken: "123:abc", EnvKey.llmApiKey: ""],
      warn: { _ in }
    )

    // when
    let secrets = try store.loadSecrets()

    // then — local servers need no key; a blank value is nil, not "".
    #expect(secrets.llmApiKey == nil)
  }

  @Test func loadWarnsThatSecretsArePlaintext() throws {
    // given
    let spy = WarningSpy()
    let store = EnvSecretStore(
      environment: [EnvKey.botToken: "123:abc"],
      warn: { spy.record($0) }
    )

    // when
    _ = try store.loadSecrets()

    // then — the env fallback must warn loudly on every load.
    #expect(spy.recorded.count == 1)
    #expect(spy.recorded.first?.contains("PLAINTEXT") == true)
  }

  @Test(arguments: [
    SecretStoreError.missingTelegramToken,
    SecretStoreError.keyFileInsecure("x"),
    SecretStoreError.malformedEnvelope,
    SecretStoreError.decryptionFailed,
    SecretStoreError.unreadable("x"),
    SecretStoreError.publicationFailed("x"),
  ]) func everySecretErrorMapsToExit11(error: SecretStoreError) {
    // then — a secret-load failure is non-retryable and exits 11 (acceptance #5/#11).
    #expect(error.exitCode == ClawExitCode.secretLoadFailed.rawValue)
    #expect(error.exitCode == 11)
  }
}
