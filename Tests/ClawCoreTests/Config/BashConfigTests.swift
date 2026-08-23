import Foundation
import Testing

@testable import ClawCore

@Suite struct BashConfigTests {
  private typealias EnvKey = AppConfig.EnvKey

  private func envWithLLM(_ base: [String: String]) -> [String: String] {
    base.merging([
      EnvKey.llmBaseURL: "http://localhost:1234/v1",
      EnvKey.llmModel: "gpt-4o",
    ]) { existing, _ in existing }
  }

  @Test func bashDefaultsToDisabledWithZshAndBoundedTimeouts() throws {
    // given
    let env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.bash == .disabledDefault)
    #expect(config.bash.enabled == false)
    #expect(config.bash.shellPath == "/bin/zsh")
    #expect(config.bash.defaultTimeoutSeconds == 30)
    #expect(config.bash.maxTimeoutSeconds == 300)
  }

  @Test func enabledBashParsesTheCompleteValidatedBlock() throws {
    // given
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[EnvKey.bashEnabled] = "true"
    env[EnvKey.bashShell] = "/bin/bash"
    env[EnvKey.bashTimeoutMax] = "600"
    env[EnvKey.bashTimeoutDefault] = "120"

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.bash.enabled)
    #expect(config.bash.shellPath == "/bin/bash")
    #expect(config.bash.defaultTimeoutSeconds == 120)
    #expect(config.bash.maxTimeoutSeconds == 600)
  }

  @Test func aLoweredCeilingPullsTheUnsetDefaultDownWithIt() throws {
    // given — the 30s default would otherwise sit above the owner's own ceiling
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[EnvKey.bashTimeoutMax] = "10"

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.bash.maxTimeoutSeconds == 10)
    #expect(config.bash.defaultTimeoutSeconds == 10)
  }

  @Test(arguments: ["bin/zsh", "zsh", "~/bin/zsh", "./zsh"])
  func aShellThatIsNotAnAbsolutePathFailsClosed(_ rawShell: String) {
    // given
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[EnvKey.bashShell] = rawShell

    // when / then
    #expect(throws: ConfigError.invalidBashShell(rawShell.trimmingCharacters(in: .whitespaces))) {
      try AppConfig.load(environment: env)
    }
  }

  @Test func anEmptyShellFallsBackToTheDefaultRatherThanFailing() throws {
    // given
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[EnvKey.bashShell] = ""

    // when
    let config = try AppConfig.load(environment: env)

    // then
    #expect(config.bash.shellPath == "/bin/zsh")
  }

  @Test(arguments: [
    (
      key: AppConfig.EnvKey.bashTimeoutMax, value: "0",
      error: ConfigError.invalidBashTimeoutMax("0")
    ),
    (
      key: AppConfig.EnvKey.bashTimeoutMax, value: "3601",
      error: ConfigError.invalidBashTimeoutMax("3601")
    ),
    (
      key: AppConfig.EnvKey.bashTimeoutMax, value: "soon",
      error: ConfigError.invalidBashTimeoutMax("soon")
    ),
    (
      key: AppConfig.EnvKey.bashTimeoutDefault, value: "0",
      error: ConfigError.invalidBashTimeoutDefault("0")
    ),
    (
      key: AppConfig.EnvKey.bashTimeoutDefault, value: "301",
      error: ConfigError.invalidBashTimeoutDefault("301")
    ),
    (
      key: AppConfig.EnvKey.bashTimeoutDefault, value: "later",
      error: ConfigError.invalidBashTimeoutDefault("later")
    ),
  ])
  func malformedBashTimeoutsFailClosed(
    _ fixture: (key: String, value: String, error: ConfigError)
  ) {
    // given
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[fixture.key] = fixture.value

    // when / then
    #expect(throws: fixture.error) {
      try AppConfig.load(environment: env)
    }
  }

  @Test func aDefaultTimeoutAboveTheConfiguredCeilingFailsClosed() {
    // given
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[EnvKey.bashTimeoutMax] = "60"
    env[EnvKey.bashTimeoutDefault] = "61"

    // when / then
    #expect(throws: ConfigError.invalidBashTimeoutDefault("61")) {
      try AppConfig.load(environment: env)
    }
  }

  @Test func aMalformedEnabledFlagFailsClosed() {
    // given
    var env = envWithLLM([EnvKey.stateRoot: NSTemporaryDirectory()])
    env[EnvKey.bashEnabled] = "maybe"

    // when / then
    #expect(throws: ConfigError.invalidBool(key: EnvKey.bashEnabled, value: "maybe")) {
      try AppConfig.load(environment: env)
    }
  }
}
