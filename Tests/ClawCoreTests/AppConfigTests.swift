import Foundation
import Testing

@testable import ClawCore

@Suite struct AppConfigTests {
  private typealias EnvKey = AppConfig.EnvKey

  @Test func loadsValidConfig() throws {
    // given
    let env = [
      EnvKey.botToken: "123:abc",
      EnvKey.allowlist: "42, 99",
      EnvKey.stateRoot: NSTemporaryDirectory(),
      EnvKey.pollTimeout: "20",
    ]

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.botToken == "123:abc")
    #expect(config.allowlist == [42, 99])
    #expect(config.pollTimeoutSeconds == 20)
  }

  @Test func missingTokenIsSecretError() {
    // given
    let env = [
      EnvKey.allowlist: "42",
      EnvKey.stateRoot: NSTemporaryDirectory(),
    ]

    // then
    #expect(throws: ConfigError.missingBotToken) {
      _ = try AppConfig.load(environment: env)
    }
  }

  @Test func emptyAllowlistIsAllowed() throws {
    // given
    let env = [
      EnvKey.botToken: "t",
      EnvKey.stateRoot: NSTemporaryDirectory(),
    ]

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.allowlist.isEmpty)
  }

  @Test func nonNumericAllowlistIsConfigError() {
    // given
    let env = [
      EnvKey.botToken: "t",
      EnvKey.allowlist: "42, notanumber",
      EnvKey.stateRoot: NSTemporaryDirectory(),
    ]

    // then
    #expect(throws: ConfigError.invalidAllowlist("notanumber")) {
      _ = try AppConfig.load(environment: env)
    }
  }

  @Test func defaultsPollTimeoutTo30() throws {
    // given
    let env = [
      EnvKey.botToken: "t",
      EnvKey.stateRoot: NSTemporaryDirectory(),
    ]

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.pollTimeoutSeconds == 30)
  }

  @Test func blankStateRootFallsBackToHomeDefaultNotCwd() throws {
    // given — copying .env.example verbatim leaves CLAW_STATE_ROOT blank
    let blankEnv = [EnvKey.botToken: "t", EnvKey.stateRoot: "   "]
    let omittedEnv = [EnvKey.botToken: "t"]

    // when
    let fromBlank = try AppConfig.load(environment: blankEnv)
    let fromOmitted = try AppConfig.load(environment: omittedEnv)

    // then — a blank value resolves like an absent one (home default), never the working dir
    let workingDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    #expect(fromBlank.stateRoot == fromOmitted.stateRoot)
    #expect(fromBlank.stateRoot.standardizedFileURL != workingDir.standardizedFileURL)
  }
}
