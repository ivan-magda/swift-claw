import Testing

@testable import ClawCore

@Suite struct ErrorTests {
  @Test func telegramErrorsAreEquatable() {
    // then
    #expect(TelegramError.conflict409(description: "x") == .conflict409(description: "x"))
    #expect(TelegramError.floodControl(retryAfter: 7) == .floodControl(retryAfter: 7))
    #expect(TelegramError.floodControl(retryAfter: 7) != .floodControl(retryAfter: 8))
  }

  @Test func exitCodesAreDistinctAndNonZero() {
    // given
    let codes: [Int32] = [
      ClawExitCode.configInvalid.rawValue,
      ClawExitCode.secretLoadFailed.rawValue,
      ClawExitCode.alreadyRunning.rawValue,
      ClawExitCode.storeError.rawValue,
    ]

    // then
    #expect(Set(codes).count == codes.count)
    #expect(codes.allSatisfy { $0 != 0 })
  }

  @Test func configErrorMapsToExitCode() {
    // then
    #expect(ConfigError.invalidAllowlist("bad").exitCode == ClawExitCode.configInvalid.rawValue)
    #expect(ConfigError.unwritableStateRoot("/x").exitCode == ClawExitCode.configInvalid.rawValue)
    #expect(
      ConfigError.invalidApprovalExpiry("999999").exitCode == ClawExitCode.configInvalid.rawValue
    )
    #expect(ConfigError.invalidExecImage("bad").exitCode == ClawExitCode.configInvalid.rawValue)
    #expect(
      ConfigError.invalidExecImageRegistry("bad").exitCode
        == ClawExitCode.configInvalid.rawValue
    )
    #expect(
      ConfigError.execImageRegistryNotAllowed("bad").exitCode
        == ClawExitCode.configInvalid.rawValue
    )
    #expect(
      ConfigError.invalidExecMemoryMiB("bad").exitCode == ClawExitCode.configInvalid.rawValue
    )
    #expect(ConfigError.invalidExecCPUs("bad").exitCode == ClawExitCode.configInvalid.rawValue)
    #expect(ConfigError.invalidExecTimeout("bad").exitCode == ClawExitCode.configInvalid.rawValue)
  }
}
