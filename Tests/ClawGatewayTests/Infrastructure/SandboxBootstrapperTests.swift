import ClawCore
import ClawTestSupport
import Testing

@testable import ClawGateway

@Suite struct SandboxBootstrapperTests {
  @Test func disabledExecutionSkipsPrepareAndReturnsNoBackend() async {
    // given
    let backend = FakeExecutionBackend()
    let bootstrapper = SandboxBootstrapper(
      enabled: false,
      backend: backend,
      maintenance: backend
    )

    // when
    let result = await bootstrapper.prepare()

    // then
    #expect(result.backend == nil)
    #expect(result.maintenance == nil)
    #expect(result.health == nil)
    #expect(result.unavailableReason == "code execution is disabled")
    #expect(await backend.prepareCallCount() == 0)
  }

  @Test func unavailableProbeFailsClosedWithoutRunningPrepare() async {
    // given
    let backend = FakeExecutionBackend(
      availability: .unavailable(reason: "container engine is stopped")
    )
    let bootstrapper = SandboxBootstrapper(
      enabled: true,
      backend: backend,
      maintenance: backend
    )

    // when
    let result = await bootstrapper.prepare()

    // then
    #expect(result.backend == nil)
    #expect(result.maintenance != nil)
    #expect(result.health == nil)
    #expect(result.unavailableReason == "container engine is stopped")
    #expect(await backend.prepareCallCount() == 0)
  }

  @Test func failedCanaryKeepsMaintenanceButWithholdsBackend() async {
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
    let backend = FakeExecutionBackend(health: health)
    let bootstrapper = SandboxBootstrapper(
      enabled: true,
      backend: backend,
      maintenance: backend
    )

    // when
    let result = await bootstrapper.prepare()

    // then
    #expect(result.backend == nil)
    #expect(result.maintenance != nil)
    #expect(result.health == health)
    #expect(result.unavailableReason == "canary reached the network")
    #expect(await backend.prepareCallCount() == 1)
  }

  @Test func passingProbeAndCanaryExposeTheBackend() async {
    // given
    let backend = FakeExecutionBackend()
    let bootstrapper = SandboxBootstrapper(
      enabled: true,
      backend: backend,
      maintenance: backend
    )

    // when
    let result = await bootstrapper.prepare()

    // then
    #expect(result.backend != nil)
    #expect(result.maintenance != nil)
    #expect(result.health?.isReady == true)
    #expect(result.unavailableReason == nil)
    #expect(await backend.prepareCallCount() == 1)
  }
}
