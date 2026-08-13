import Testing

@testable import ClawCore

@Suite struct ExecutionContractsTests {
  @Test func healthIsReadyWhenEveryGatePasses() {
    // given
    let health = SandboxHealth.passingForTests

    // when
    let isReady = health.isReady

    // then
    #expect(isReady)
  }

  @Test func healthIsNotReadyWhenAnyGateFails() {
    // given
    let failedHealth = HealthGate.allCases.map(Self.health(failing:))

    // when
    let readiness = failedHealth.map(\.isReady)

    // then
    #expect(readiness == Array(repeating: false, count: HealthGate.allCases.count))
  }
}

// MARK: - Health Fixtures

private extension ExecutionContractsTests {
  enum HealthGate: CaseIterable {
    case available
    case operatingSystem
    case version
    case imageDigest
    case emptyCapabilities
    case networkIsolation
    case matchingCapabilities
    case reaper
    case readOnlyRoot
    case readOnlyStaging
    case interpreters
    case lastError
  }

  static func health(failing gate: HealthGate) -> SandboxHealth {
    var available = true
    var osOK = true
    var versionOK = true
    var imageDigestOK = true
    var capsEmpty = true
    var netIsolated = true
    var capsMatch = true
    var reaperOK = true
    var rootfsRO = true
    var stagingRO = true
    var interpretersOK = true
    var lastError: String?

    switch gate {
    case .available: available = false
    case .operatingSystem: osOK = false
    case .version: versionOK = false
    case .imageDigest: imageDigestOK = false
    case .emptyCapabilities: capsEmpty = false
    case .networkIsolation: netIsolated = false
    case .matchingCapabilities: capsMatch = false
    case .reaper: reaperOK = false
    case .readOnlyRoot: rootfsRO = false
    case .readOnlyStaging: stagingRO = false
    case .interpreters: interpretersOK = false
    case .lastError: lastError = "probe failed"
    }

    return SandboxHealth(
      available: available,
      osOK: osOK,
      engineVersion: "1.1.0",
      versionOK: versionOK,
      imageDigestOK: imageDigestOK,
      capsEmpty: capsEmpty,
      netIsolated: netIsolated,
      capsMatch: capsMatch,
      reaperOK: reaperOK,
      rootfsRO: rootfsRO,
      stagingRO: stagingRO,
      interpretersOK: interpretersOK,
      lastError: lastError
    )
  }
}
