import ClawCore
import Foundation
import Testing

@testable import ClawExec

@Suite struct ContainerBackendProbeTests {
  @Test func probeRejectsUnsupportedHostBeforeAnySubprocess() async throws {
    // given
    let fixture = try BackendFixture()
    defer { fixture.remove() }
    let runner = ScriptedCommandRunner { _, _ in
      commandResult(.exited(0))
    }
    let backend = fixture.backend(commands: runner, supportedHost: { false })

    // when
    let availability = await backend.probe()

    // then
    #expect(
      availability == .unavailable(reason: "execute_code requires macOS 26 or newer on arm64")
    )
    #expect(await runner.recorded().isEmpty)
  }

  @Test func versionAvailabilityRejectsUnsupportedHostBeforeAnySubprocess() async throws {
    // given
    let fixture = try BackendFixture()
    defer { fixture.remove() }
    let runner = ScriptedCommandRunner { _, _ in
      commandResult(.exited(0))
    }
    let backend = fixture.backend(commands: runner, supportedHost: { false })

    // when
    let availability = await backend.versionAvailability()

    // then
    #expect(
      availability == .unavailable(reason: "execute_code requires macOS 26 or newer on arm64")
    )
    #expect(await runner.recorded().isEmpty)
  }

  @Test func probeRequiresRunningTypedSystemStatus() async throws {
    // given
    let fixture = try BackendFixture()
    defer { fixture.remove() }
    let runner = ScriptedCommandRunner { command, _ in
      command.arguments == ContainerInvocation.systemStatus()
        ? jsonCommandResult(#"{"status":"not running"}"#)
        : jsonCommandResult("[]")
    }
    let backend = fixture.backend(commands: runner, supportedHost: { true })

    // when
    let availability = await backend.probe()

    // then
    #expect(availability == .unavailable(reason: "container engine is not running"))
    #expect(await runner.recorded().map(\.arguments) == [ContainerInvocation.systemStatus()])
  }

  @Test func versionAvailabilitySelectsCLIComponentAndAcceptsTheFloor() async throws {
    // given
    let fixture = try BackendFixture()
    defer { fixture.remove() }
    let json = """
      [
        {"version":"99.0.0","buildType":"release","commit":"server","appName":"container-apiserver"},
        {"version":"1.0.0","buildType":"release","commit":"cli","appName":"container"}
      ]
      """
    let runner = ScriptedCommandRunner { command, _ in
      command.arguments == ContainerInvocation.systemVersion()
        ? jsonCommandResult(json)
        : jsonCommandResult(#"{"status":"running"}"#)
    }
    let backend = fixture.backend(commands: runner, supportedHost: { true })

    // when
    let direct = await backend.versionAvailability()
    let probe = await backend.probe()

    // then
    #expect(direct == .available(engineVersion: "1.0.0"))
    #expect(probe == .available(engineVersion: "1.0.0"))
  }

  @Test(arguments: [
    "0.12.3",
    "1.0",
    "v1.0.0",
    "1.0.0-beta.1",
  ])
  func versionAvailabilityFailsClosedForOldOrMalformedCLI(version: String) async throws {
    // given
    let fixture = try BackendFixture()
    defer { fixture.remove() }
    let json = """
      [{"version":"\(version)","buildType":"release","commit":"cli","appName":"container"}]
      """
    let runner = ScriptedCommandRunner { _, _ in
      jsonCommandResult(json)
    }
    let backend = fixture.backend(commands: runner, supportedHost: { true })

    // when
    let availability = await backend.versionAvailability()

    // then
    guard case .unavailable = availability else {
      Issue.record("expected unavailable for \(version)")
      return
    }
  }

  @Test func truncatedOrMalformedVersionJSONFailsClosed() async throws {
    // given
    let fixture = try BackendFixture()
    defer { fixture.remove() }
    let runner = ScriptedCommandRunner { _, history in
      history.count == 1
        ? commandResult(
          .exited(0),
          stdout: Data("[]".utf8),
          stdoutTotal: 2_000_000,
          stdoutTruncated: true
        )
        : jsonCommandResult("not-json")
    }
    let backend = fixture.backend(commands: runner, supportedHost: { true })

    // when
    let truncated = await backend.versionAvailability()
    let malformed = await backend.versionAvailability()

    // then
    guard case .unavailable = truncated else {
      Issue.record("truncation must fail closed")
      return
    }
    guard case .unavailable = malformed else {
      Issue.record("malformed JSON must fail closed")
      return
    }
  }
}
