import Testing

@testable import ClawCore

@Suite
struct ErrorTests {
  @Test
  func exitCodesAreDistinctAndNonZero() {
    // given
    let codes: [Int32] = [
      ClawExitCode.configInvalid.rawValue,
      ClawExitCode.secretLoadFailed.rawValue,
      ClawExitCode.alreadyRunning.rawValue,
      ClawExitCode.storeError.rawValue,
    ]

    // then
    #expect(Set(codes).count == codes.count)
    #expect(
      codes.allSatisfy {
        $0 != 0
      }
    )
  }

  @Test
  func configErrorExitsAsConfigInvalid() {
    // given — every case shares one exit code, so one case pins it
    let error = ConfigError.invalidAllowlist("bad")

    // when / then
    #expect(error.exitCode == ClawExitCode.configInvalid.rawValue)
  }
}
