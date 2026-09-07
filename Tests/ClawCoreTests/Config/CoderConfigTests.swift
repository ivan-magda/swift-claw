import Foundation
import Testing

@testable import ClawCore

@Suite struct CoderConfigTests {
  private typealias EnvKey = AppConfig.EnvKey

  @Test func defaultsAndInvalidLimits() throws {
    // given
    let defaults = try CoderConfig.load(environment: [:])

    // when
    let invalid = Result {
      try CoderConfig.load(environment: [EnvKey.coderMaxConcurrentJobs: "0"])
    }

    // then
    #expect(defaults.enabled == false)
    #expect(defaults.maxConcurrentJobs == CoderConfig.Defaults.maxConcurrentJobs)
    #expect(defaults.jobTimeoutSeconds == CoderConfig.Defaults.jobTimeoutSeconds)
    #expect(defaults.executable == CoderConfig.Defaults.executable)
    #expect(defaults.profile == nil)
    #expect(defaults.configHome == nil)
    #expect(throws: ConfigError.invalidCoderSetting(key: EnvKey.coderMaxConcurrentJobs)) {
      try invalid.get()
    }
  }

  @Test(arguments: [
    (EnvKey.coderMaxConcurrentJobs, "many"),
    (EnvKey.coderJobTimeoutSeconds, "86401"),
    (EnvKey.coderJobTimeoutSeconds, "0"),
  ]) func invalidScalarCategories(key: String, value: String) {
    // given
    let environment = [key: value]

    // when
    let load = { try CoderConfig.load(environment: environment) }

    // then
    #expect(throws: ConfigError.invalidCoderSetting(key: key)) {
      try load()
    }
  }

  @Test func enabledUsesStrictBooleanParser() {
    // given
    let environment = [EnvKey.coderEnabled: "sometimes"]

    // when
    let load = { try CoderConfig.load(environment: environment) }

    // then
    #expect(throws: ConfigError.invalidBool(key: EnvKey.coderEnabled, value: "sometimes")) {
      try load()
    }
  }

  @Test(arguments: [
    (EnvKey.coderExecutable, "codex --flag"),
    (EnvKey.coderExecutable, "bin/codex"),
    (EnvKey.coderExecutable, "--codex"),
    (EnvKey.coderConfigHome, "relative/config"),
    (EnvKey.coderProfile, ""),
  ]) func invalidTextSettings(key: String, value: String) {
    // given
    let environment = [key: value]

    // when
    let load = { try CoderConfig.load(environment: environment) }

    // then
    #expect(throws: ConfigError.invalidCoderSetting(key: key)) {
      try load()
    }
  }
}
