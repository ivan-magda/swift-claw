import ClawCore
import ClawTestSupport
import Foundation
import Testing

@testable import ClawAuth

/// Config an auth command must never need. Every key here is one `AppConfig.load` would refuse, so a
/// bootstrap that quietly grew a dependency on daemon config would stop resolving.
private enum HostileDaemonConfig {
  static let entries = [
    "CLAW_ALLOWLIST": "not-a-chat-id",
    "CLAW_TIMEZONE": "Mars/Olympus_Mons",
    "CLAW_HEARTBEAT_ENABLED": "perhaps",
    "CLAW_PER_RUN_USD": "free",
    "CLAW_SCHED_MIN_INTERVAL_MINUTES": "-4",
  ]
}

@Suite struct AuthBootstrapTests {
  // MARK: - The State Root

  @Test func theStateRootIsCreatedAtTheModeDaemonConfigWouldHaveUsed() throws {
    // given
    let parent = try makeTemporaryRoot(prefix: "auth-bootstrap-root")
    defer { try? FileManager.default.removeItem(at: parent) }
    let named = parent.appendingPathComponent("root", isDirectory: true)

    // when
    let bootstrap = try AuthBootstrap.resolve(environment: [
      AppConfig.EnvKey.stateRoot: named.path
    ])

    // then
    #expect(bootstrap.stateRoot.standardizedFileURL == named.standardizedFileURL)
    let attributes = try FileManager.default.attributesOfItem(atPath: named.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
  }

  @Test func anAbsentStateRootResolvesToTheSameDefaultDaemonConfigUses() throws {
    // given / when
    let bootstrap = try AuthBootstrap.resolve(environment: [:])

    // then
    let expected = try StateRootResolver.createStateRoot(for: nil)
    #expect(bootstrap.stateRoot.standardizedFileURL == expected.standardizedFileURL)
  }

  // MARK: - Narrowness

  /// The reason the bootstrap exists: status has to be able to diagnose auth on an installation
  /// whose daemon config is broken, and login has to be able to discover a model before any model is
  /// configured. Both die if this ever starts loading `AppConfig`.
  @Test func resolvingSucceedsOnConfigTheDaemonWouldRefuseToBootOn() throws {
    // given
    let root = try makeTemporaryRoot(prefix: "auth-bootstrap-narrow")
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = HostileDaemonConfig.entries.merging([
      AppConfig.EnvKey.stateRoot: root.path
    ]) { existing, _ in existing }

    // when
    let bootstrap = try AuthBootstrap.resolve(environment: environment)

    // then
    #expect(bootstrap.stateRoot.standardizedFileURL == root.standardizedFileURL)
    #expect(bootstrap.configuredModel == nil)
    // The pairing that stops the case above from passing for the wrong reason: this same
    // environment really is config the daemon refuses.
    #expect(throws: ConfigError.self) {
      try AppConfig.load(environment: environment)
    }
  }

  @Test func resolvingNeedsNoAllowlistBaseURLModelBudgetOrScheduler() throws {
    // given
    let root = try makeTemporaryRoot(prefix: "auth-bootstrap-bare")
    defer { try? FileManager.default.removeItem(at: root) }

    // when
    let bootstrap = try AuthBootstrap.resolve(environment: [
      AppConfig.EnvKey.stateRoot: root.path
    ])

    // then
    #expect(bootstrap.configuredModel == nil)
    // Same pairing: a bare environment is exactly what daemon config refuses, for want of a model.
    #expect(throws: ConfigError.self) {
      try AppConfig.load(environment: [AppConfig.EnvKey.stateRoot: root.path])
    }
  }

  // MARK: - The Configured Model

  /// Read raw and unvalidated. Deciding what a model reference means belongs to selection and to
  /// status; a bootstrap that refused a model would be the very failure it exists to survive.
  @Test(arguments: [
    "openai-chatgpt/gpt-5.4",
    "gpt-4o",
    "",
    "   ",
    "openai-chatgpt/!!not-a-valid-suffix",
  ])
  func theConfiguredModelIsReadVerbatim(raw: String) throws {
    // given
    let root = try makeTemporaryRoot(prefix: "auth-bootstrap-model")
    defer { try? FileManager.default.removeItem(at: root) }

    // when
    let bootstrap = try AuthBootstrap.resolve(environment: [
      AppConfig.EnvKey.stateRoot: root.path,
      AppConfig.EnvKey.llmModel: raw,
    ])

    // then
    #expect(bootstrap.configuredModel == raw)
  }

  // MARK: - Process Isolation

  /// The supplied dictionary is the whole environment. A bootstrap that read or exported the
  /// process's own would make every auth command depend on how its shell happened to be started.
  @Test func resolvingReadsTheSuppliedDictionaryAndExportsNothing() throws {
    // given — snapshot only the keys a bootstrap could plausibly write, so the assertion is about
    // what resolve() exports, not about whatever the ambient shell happens to have set.
    let root = try makeTemporaryRoot(prefix: "auth-bootstrap-isolation")
    defer { try? FileManager.default.removeItem(at: root) }
    let writableKeys = [AppConfig.EnvKey.stateRoot, AppConfig.EnvKey.llmModel]
    let before = writableKeys.map { ProcessInfo.processInfo.environment[$0] }

    // when
    let bootstrap = try AuthBootstrap.resolve(environment: [
      AppConfig.EnvKey.stateRoot: root.path,
      AppConfig.EnvKey.llmModel: "openai-chatgpt/gpt-5.4",
    ])

    // then
    #expect(bootstrap.stateRoot.standardizedFileURL == root.standardizedFileURL)
    #expect(bootstrap.configuredModel == "openai-chatgpt/gpt-5.4")
    let after = writableKeys.map { ProcessInfo.processInfo.environment[$0] }
    #expect(after == before)
  }
}
