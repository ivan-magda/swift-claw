import ClawCore
import Foundation
import Testing

@testable import ClawGateway

@Suite struct BashHealthRowsTests {
  @Test func disabledHostShellIsInformational() {
    // given / when
    let rows = BashHealthRows.rows(for: .disabled)

    // then
    #expect(
      rows == [
        .init(key: "bash", value: "disabled by CLAW_BASH_ENABLED", ok: true, group: .hostShell)
      ]
    )
  }

  @Test func unavailableShellFailsAndNamesTheReason() {
    // given / when
    let rows = BashHealthRows.rows(
      for: .unavailable(shellPath: "/bin/zsh", reason: "no file at /bin/zsh")
    )

    // then
    #expect(
      rows == [
        .init(key: "bash.available", value: "false", ok: false, group: .hostShell),
        .init(key: "bash.shell", value: "/bin/zsh", ok: false, group: .hostShell),
        .init(key: "bash.last_error", value: "no file at /bin/zsh", ok: false, group: .hostShell),
      ]
    )
  }

  @Test func readyShellReportsItsBounds() {
    // given / when
    let rows = BashHealthRows.rows(
      for: .ready(shellPath: "/bin/zsh", defaultTimeoutSeconds: 30, maxTimeoutSeconds: 300)
    )

    // then
    #expect(
      rows == [
        .init(key: "bash.available", value: "true", ok: true, group: .hostShell),
        .init(key: "bash.shell", value: "/bin/zsh", ok: true, group: .hostShell),
        .init(
          key: "bash.timeout",
          value: "30s default (maximum 300s)",
          ok: true,
          group: .hostShell
        ),
      ]
    )
  }

  @Test func disabledConfigResolvesToDisabledWhateverTheShell() {
    // given
    let config = BashConfig(
      enabled: false,
      shellPath: "/nonexistent/shell",
      defaultTimeoutSeconds: 30,
      maxTimeoutSeconds: 300
    )

    // when
    let status = BashDoctorStatus.resolve(config: config)

    // then
    #expect(status == .disabled)
  }

  @Test func enabledConfigWithAMissingShellResolvesToUnavailable() {
    // given
    let shellPath = NSTemporaryDirectory() + "clawd-missing-shell-" + UUID().uuidString
    let config = BashConfig(
      enabled: true,
      shellPath: shellPath,
      defaultTimeoutSeconds: 30,
      maxTimeoutSeconds: 300
    )

    // when
    let status = BashDoctorStatus.resolve(config: config)

    // then
    #expect(status == .unavailable(shellPath: shellPath, reason: "no file at \(shellPath)"))
  }

  @Test func enabledConfigWithALaunchableShellResolvesToReady() {
    // given
    let config = BashConfig(
      enabled: true,
      shellPath: "/bin/sh",
      defaultTimeoutSeconds: 15,
      maxTimeoutSeconds: 120
    )

    // when
    let status = BashDoctorStatus.resolve(config: config)

    // then
    #expect(
      status == .ready(shellPath: "/bin/sh", defaultTimeoutSeconds: 15, maxTimeoutSeconds: 120)
    )
  }
}
