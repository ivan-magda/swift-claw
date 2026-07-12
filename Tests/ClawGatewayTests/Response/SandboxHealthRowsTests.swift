import ClawCore
import Testing

@testable import ClawGateway

@Suite struct SandboxHealthRowsTests {
  @Test func disabledExecutionIsInformational() {
    // given / when
    let rows = SandboxHealthRows.rows(for: .disabled)

    // then
    #expect(
      rows == [
        .init(key: "sandbox", value: "disabled by CLAW_EXEC_ENABLED", ok: true)
      ]
    )
  }

  @Test func linuxDeferralIsInformational() {
    // given / when
    let rows = SandboxHealthRows.rows(for: .linuxDeferred)

    // then
    #expect(rows.count == 1)
    #expect(rows[0].key == "sandbox")
    #expect(rows[0].value == "execute_code awaits the Linux backend")
    #expect(rows[0].ok)
  }

  @Test func configOnlyReportsVersionAndDefersTheCanary() {
    // given / when
    let rows = SandboxHealthRows.rows(
      for: .configOnly(availability: .available(engineVersion: "1.1.0"))
    )

    // then
    #expect(
      rows.map(\.key) == [
        "sandbox.available",
        "sandbox.os_ok",
        "sandbox.engine_version",
        "sandbox.version_ok",
        "sandbox.canary",
      ]
    )
    #expect(rows.allSatisfy { $0.ok })
    #expect(rows.last?.value == "deferred until live daemon startup")
  }

  @Test func configOnlyBelowFloorFailsClosed() {
    // given / when
    let rows = SandboxHealthRows.rows(
      for: .configOnly(
        availability: .unavailable(reason: "container 0.9.0 is below minimum 1.0.0")
      )
    )

    // then
    #expect(
      rows.map(\.key) == [
        "sandbox.available",
        "sandbox.os_ok",
        "sandbox.engine_version",
        "sandbox.version_ok",
        "sandbox.last_error",
      ]
    )
    #expect(rows.allSatisfy { $0.ok == false })
    #expect(rows.last?.value.contains("0.9.0") == true)
  }

  @Test func passingLiveSnapshotRendersEveryGateGreen() {
    // given / when
    let rows = SandboxHealthRows.rows(for: .live(health: .passingForTests))

    // then
    #expect(
      rows.map(\.key) == [
        "sandbox.available",
        "sandbox.os_ok",
        "sandbox.engine_version",
        "sandbox.version_ok",
        "sandbox.image_digest_ok",
        "sandbox.caps_empty",
        "sandbox.net_isolated",
        "sandbox.caps_match",
        "sandbox.reaper_ok",
        "sandbox.rootfs_ro",
        "sandbox.staging_ro",
        "sandbox.interpreters_ok",
        "sandbox.last_error",
      ]
    )
    #expect(rows.allSatisfy { $0.ok })
  }

  @Test func failedLiveAssertionAndErrorAreBothLoud() {
    // given
    let health = SandboxHealth(
      available: true,
      osOK: true,
      engineVersion: "1.1.0",
      versionOK: true,
      imageDigestOK: true,
      capsEmpty: true,
      netIsolated: false,
      capsMatch: true,
      reaperOK: true,
      rootfsRO: true,
      stagingRO: true,
      interpretersOK: true,
      lastError: "canary reached the network"
    )

    // when
    let rows = SandboxHealthRows.rows(for: .live(health: health))

    // then
    #expect(rows.first { $0.key == "sandbox.net_isolated" }?.ok == false)
    #expect(rows.first { $0.key == "sandbox.last_error" }?.ok == false)
    #expect(rows.first { $0.key == "sandbox.last_error" }?.value == health.lastError)
  }

  @Test func unavailableBootstrapIsLoud() {
    // given / when
    let rows = SandboxHealthRows.rows(
      for: .unavailable(reason: "container engine is stopped")
    )

    // then
    #expect(
      rows.map(\.key) == [
        "sandbox.available",
        "sandbox.os_ok",
        "sandbox.engine_version",
        "sandbox.version_ok",
        "sandbox.image_digest_ok",
        "sandbox.caps_empty",
        "sandbox.net_isolated",
        "sandbox.caps_match",
        "sandbox.reaper_ok",
        "sandbox.rootfs_ro",
        "sandbox.staging_ro",
        "sandbox.interpreters_ok",
        "sandbox.last_error",
      ]
    )
    #expect(rows.allSatisfy { $0.ok == false })
    #expect(rows.last?.value == "container engine is stopped")
  }
}
