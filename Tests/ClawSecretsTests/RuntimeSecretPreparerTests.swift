import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawSecrets

@Suite struct RuntimeSecretPreparerTests {
  private typealias EnvKey = EnvSecretStore.EnvKey

  private static let fullEnvironment = [
    EnvKey.botToken: "123:telegram",
    EnvKey.llmApiKey: "sk-unused-by-chatgpt",
    EnvKey.searchApiKey: "search-key",
  ]

  // MARK: - The transition

  @Test func withNeitherArtifactPresentPreparationSealsTheEnvironmentSecrets() throws {
    // given — an environment-backed installation: no encrypted artifact exists yet.
    let stateRoot = try makeTemporaryRoot(prefix: "claw-prepare")
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    // when
    let prepared = try RuntimeSecretPreparer.prepare(
      stateRoot: stateRoot,
      environment: Self.fullEnvironment
    )

    // then — both artifacts exist and the encrypted backend is now authoritative for them.
    #expect(
      try entryNames(in: stateRoot)
        == [
          SecretStatePaths.keyName, SecretStatePaths.runtimeEnvelopeName,
        ].sorted()
    )
    #expect(prepared.telegramBotToken == "123:telegram")
    #expect(try EncryptedFileSecretStore(stateRoot: stateRoot).loadSecrets() == prepared)
    #expect(
      SecretStoreResolver.resolve(
        stateRoot: stateRoot,
        environment: [:],
        warn: { _ in }
      ).backend == .encrypted
    )
  }

  @Test func aChatGPTLoginStillPreservesTheApiKeyItDoesNotNeed() throws {
    // given — a ChatGPT route never reads CLAW_LLM_API_KEY, but Telegram and search must stay
    // bootable once the encrypted backend takes over.
    let stateRoot = try makeTemporaryRoot(prefix: "claw-prepare")
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    // when
    let prepared = try RuntimeSecretPreparer.prepare(
      stateRoot: stateRoot,
      environment: Self.fullEnvironment
    )

    // then
    #expect(prepared.llmApiKey == "sk-unused-by-chatgpt")
    #expect(prepared.searchApiKey == "search-key")
    #expect(prepared.telegramBotToken == "123:telegram")
  }

  @Test func withBothArtifactsPresentPreparationDecryptsAndLeavesTheBytesAlone() throws {
    // given — an already-encrypted installation whose env holds different, stale values.
    let stateRoot = try makeTemporaryRoot(prefix: "claw-prepare")
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    let sealed = Secrets(telegramBotToken: "999:sealed", llmApiKey: "sk-sealed")
    try EncryptedFileSecretStore.seal(sealed, stateRoot: stateRoot)
    let paths = SecretStatePaths(stateRoot: stateRoot)
    let envelopeBefore = try Data(contentsOf: paths.runtimeEnvelope)
    let keyBefore = try Data(contentsOf: paths.key)

    // when
    let prepared = try RuntimeSecretPreparer.prepare(
      stateRoot: stateRoot,
      environment: Self.fullEnvironment
    )

    // then — the on-disk value wins and nothing is rewritten.
    #expect(prepared == sealed)
    #expect(try Data(contentsOf: paths.runtimeEnvelope) == envelopeBefore)
    #expect(try Data(contentsOf: paths.key) == keyBefore)
  }

  @Test(arguments: [SecretStatePaths.keyName, SecretStatePaths.runtimeEnvelopeName])
  func withExactlyOneArtifactPresentPreparationFailsClosedAndMintsNothing(
    survivor: String
  ) throws {
    // given — a partial encrypted setup. Login must not mint the missing half.
    let stateRoot = try makeTemporaryRoot(prefix: "claw-prepare")
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    try EncryptedFileSecretStore.seal(
      Secrets(telegramBotToken: "999:sealed", llmApiKey: nil),
      stateRoot: stateRoot
    )
    let paths = SecretStatePaths(stateRoot: stateRoot)
    let doomed = survivor == SecretStatePaths.keyName ? paths.runtimeEnvelope : paths.key
    try FileManager.default.removeItem(at: doomed)

    // when / then — the same fail-closed diagnostic the daemon gets at startup; never the env token.
    #expect(throws: SecretStoreError.self) {
      _ = try RuntimeSecretPreparer.prepare(
        stateRoot: stateRoot,
        environment: Self.fullEnvironment
      )
    }
    #expect(try entryNames(in: stateRoot) == [survivor])
  }

  @Test func aMissingTelegramTokenFailsBeforeAnythingIsCreated() throws {
    // given — the one required runtime secret is absent from the environment.
    let stateRoot = try makeTemporaryRoot(prefix: "claw-prepare")
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    // when / then
    #expect(throws: SecretStoreError.missingTelegramToken) {
      _ = try RuntimeSecretPreparer.prepare(
        stateRoot: stateRoot,
        environment: [EnvKey.llmApiKey: "sk-only"]
      )
    }
    #expect(try entryNames(in: stateRoot).isEmpty)
  }

  // MARK: - Rollback

  @Test func aFailedEnvelopePublicationRemovesEveryArtifactTheSealCreated() throws {
    // given — a transition from an environment-backed installation.
    let stateRoot = try makeTemporaryRoot(prefix: "claw-prepare")
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    // when — the key lands, then the envelope's commit never happens.
    #expect(throws: SecretStoreError.self) {
      _ = try RuntimeSecretPreparer.prepare(
        stateRoot: stateRoot,
        environment: Self.fullEnvironment,
        publisher: SecureFilePublisher(failpoint: .init(.commit, on: SecretFile.envelope))
      )
    }

    // then — no half-sealed state survives; the installation is still environment-backed.
    #expect(try entryNames(in: stateRoot).isEmpty)
    #expect(
      SecretStoreResolver.resolve(
        stateRoot: stateRoot,
        environment: Self.fullEnvironment,
        warn: { _ in }
      ).backend == .env
    )
  }

  @Test func anUncertainEnvelopeCommitAlsoUnwindsTheWholeTransition() throws {
    // given
    let stateRoot = try makeTemporaryRoot(prefix: "claw-prepare")
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    // when — the envelope's rename landed but its durability is unproven, so the seal cannot be
    // reported as done; both artifacts it created come back out.
    #expect(throws: SecretStoreError.self) {
      _ = try RuntimeSecretPreparer.prepare(
        stateRoot: stateRoot,
        environment: Self.fullEnvironment,
        publisher: SecureFilePublisher(failpoint: .init(.directorySync, on: SecretFile.envelope))
      )
    }

    // then
    #expect(try entryNames(in: stateRoot).isEmpty)
  }

  @Test func rollbackNeverRemovesAKeyTheSealDidNotCreate() throws {
    // given — a key the owner already had (a re-seal, not a transition).
    let stateRoot = try makeTemporaryRoot(prefix: "claw-prepare")
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    try EncryptedFileSecretStore.seal(
      Secrets(telegramBotToken: "999:sealed", llmApiKey: nil),
      stateRoot: stateRoot
    )
    let paths = SecretStatePaths(stateRoot: stateRoot)
    let keyBefore = try Data(contentsOf: paths.key)
    let envelopeBefore = try Data(contentsOf: paths.runtimeEnvelope)

    // when
    #expect(throws: SecretStoreError.self) {
      _ = try EncryptedFileSecretStore.seal(
        Secrets(telegramBotToken: "111:new", llmApiKey: nil),
        stateRoot: stateRoot,
        publisher: SecureFilePublisher(failpoint: .init(.commit, on: SecretFile.envelope))
      )
    }

    // then — a pre-existing artifact is not this operation's to delete, and the pre-commit failure
    // left the old envelope whole.
    #expect(try Data(contentsOf: paths.key) == keyBefore)
    #expect(try Data(contentsOf: paths.runtimeEnvelope) == envelopeBefore)
    #expect(
      try EncryptedFileSecretStore(stateRoot: stateRoot).loadSecrets().telegramBotToken
        == "999:sealed"
    )
  }

  @Test func rollbackRemovesTheEnvelopeBeforeTheKey() throws {
    // given — a transition that created both artifacts.
    let stateRoot = try makeTemporaryRoot(prefix: "claw-prepare")
    defer { try? FileManager.default.removeItem(at: stateRoot) }

    let publisher = SecureFilePublisher()
    var created = CreatedRuntimeArtifacts()
    let key = try EncryptedFileSecretStore.ensureKey(
      at: SecretStatePaths(stateRoot: stateRoot).key,
      publisher: publisher,
      created: &created
    )
    try EncryptedFileSecretStore.publishEnvelope(
      EncryptedFileSecretStore.sealEnvelope(Data("plaintext".utf8), key: key),
      paths: SecretStatePaths(stateRoot: stateRoot),
      publisher: publisher,
      created: &created
    )

    // when
    let plan = created.removalPlan

    // then — the envelope goes first: the key alone is inert, whereas an envelope pointing at a
    // key that is already gone is the exact partial state the resolver refuses to boot on.
    let paths = SecretStatePaths(stateRoot: stateRoot)
    #expect(plan.map(\.url) == [paths.runtimeEnvelope, paths.key])
  }
}
