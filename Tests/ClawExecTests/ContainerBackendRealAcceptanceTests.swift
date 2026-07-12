import ClawCore
import Foundation
import Testing

@testable import ClawExec

// The whole suite is skipped unless the owner opts in on a real macOS 26 arm64 host. It boots real
// Virtualization.framework VMs, so it is serialized and never runs on the hermetic CI path.
@Suite(
  .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["CLAW_REAL_SANDBOX_TESTS"] == "1")
)
struct ContainerBackendRealAcceptanceTests {
  @Test func helloWorldRoundTripsGuestStdout() async throws {
    // given
    let host = try RealSandboxHost()
    defer { host.remove() }
    let backend = try await host.readyBackend()
    defer { Task { await backend.shutdown() } }

    // when
    let result = await backend.run(host.shellRequest("printf 'hello-from-guest\\n'"))

    // then
    #expect(result.terminationReason == .exited(code: 0))
    #expect(result.stdout.contains("hello-from-guest"))
    #expect(try await host.ownedNames(backend).isEmpty)
  }

  @Test func runPastItsTimeoutIsKilledAndReapedWithinTheOuterDeadline() async throws {
    // given
    let host = try RealSandboxHost()
    defer { host.remove() }
    let backend = try await host.readyBackend()
    defer { Task { await backend.shutdown() } }

    // when
    let started = ContinuousClock.now
    let result = await backend.run(host.shellRequest("sleep 600", timeout: .seconds(2)))
    let elapsed = started.duration(to: ContinuousClock.now)

    // then — program budget fires, teardown runs, nothing is left behind
    #expect(result.terminationReason == .timedOutKilled)
    #expect(elapsed < .seconds(2) + ContainerBackend.teardownAllowance + .seconds(30))
    #expect(try await host.ownedNames(backend).isEmpty)
  }

  @Test func freshInstanceIsNeverReusedBetweenRuns() async throws {
    // given
    let host = try RealSandboxHost()
    defer { host.remove() }
    let backend = try await host.readyBackend()
    defer { Task { await backend.shutdown() } }

    // when — run N writes a marker into the disposable /tmp
    let first = await backend.run(
      host.shellRequest("echo marker > /tmp/claw-marker; cat /tmp/claw-marker")
    )
    let second = await backend.run(
      host.shellRequest(
        "if [ -e /tmp/claw-marker ]; then echo REUSED; else echo fresh-instance; fi"
      )
    )

    // then — run N+1 is a fresh VM that never saw the marker
    #expect(first.terminationReason == .exited(code: 0))
    #expect(first.stdout.contains("marker"))
    #expect(second.stdout.contains("fresh-instance"))
    #expect(!second.stdout.contains("REUSED"))
  }

  @Test func hostSecretsAndHostFilesAreUnreachableFromTheGuest() async throws {
    // given — a sentinel in the process environment and a sentinel file in the host home
    let host = try RealSandboxHost()
    defer { host.remove() }
    let backend = try await host.readyBackend()
    defer { Task { await backend.shutdown() } }
    let sentinel = "layer-b-host-sentinel-\(UUID().uuidString)"
    let homeSentinel = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".claw-layerb-sentinel")
    try sentinel.write(to: homeSentinel, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: homeSentinel) }
    setenv("CLAW_LAYERB_HOST_SENTINEL", sentinel, 1)
    defer { unsetenv("CLAW_LAYERB_HOST_SENTINEL") }

    // when — the guest dumps its env and tries to read the host file by absolute and $HOME path
    let script = """
      env
      cat \(homeSentinel.path) 2>/dev/null || true
      cat "$HOME/.claw-layerb-sentinel" 2>/dev/null || true
      echo probe-done
      """
    let result = await backend.run(host.shellRequest(script))

    // then — the fresh VM inherits no host env and mounts no host path, so the sentinel never leaks
    #expect(result.stdout.contains("probe-done"))
    #expect(!result.stdout.contains(sentinel))
    #expect(!result.stderr.contains(sentinel))
  }

  @Test func stagingMountIsReadOnlyFromInsideTheGuest() async throws {
    // given
    let host = try RealSandboxHost()
    defer { host.remove() }
    let backend = try await host.readyBackend()
    defer { Task { await backend.shutdown() } }
    let staged = StagedFile(name: "input.txt", bytes: Data("staged-content".utf8), mode: .readOnly)

    // when — the guest reads the input, then tries to write, create, and chmod under /work
    let script = """
      set -e
      test "$(cat /work/input.txt)" = "staged-content"
      if echo mutate > /work/input.txt 2>/dev/null; then echo FAIL-write; exit 11; fi
      if : > /work/created 2>/dev/null; then echo FAIL-create; exit 12; fi
      if chmod 0700 /work/input.txt 2>/dev/null; then echo FAIL-chmod; exit 13; fi
      echo staging-readonly-ok
      """
    let result = await backend.run(host.shellRequest(script, inputs: [staged]))

    // then — every mutation of the read-only bind fails; the read succeeds
    #expect(result.terminationReason == .exited(code: 0))
    #expect(result.stdout.contains("staging-readonly-ok"))
    #expect(!result.stdout.contains("FAIL"))
  }

  @Test func networkIsDeniedWhenEgressIsOff() async throws {
    // given
    let host = try RealSandboxHost()
    defer { host.remove() }
    let backend = try await host.readyBackend()
    defer { Task { await backend.shutdown() } }

    // when — a network:false run attempts a raw outbound TCP connection (no DNS dependence)
    let script = """
      /usr/bin/python - <<'PY'
      import socket
      socket.setdefaulttimeout(5)
      try:
          socket.create_connection(("1.1.1.1", 53))
          print("NETWORK-REACHABLE")
      except OSError:
          print("network-denied-ok")
      PY
      """
    let result = await backend.run(host.shellRequest(script, network: false))

    // then
    #expect(result.stdout.contains("network-denied-ok"))
    #expect(!result.stdout.contains("NETWORK-REACHABLE"))
  }

  @Test func preparedCanaryProvesEveryHardeningBit() async throws {
    // given — non-default caps so the host inspect assertions exercise exact configured values
    let host = try RealSandboxHost()
    defer { host.remove() }
    let backend = host.backend(memoryMiB: 512, cpus: 2)

    // when
    let health = await backend.prepare()
    defer { Task { await backend.shutdown() } }

    // then — the seven §8 canary assertions plus the host/version gates all hold
    #expect(health.isReady)
    #expect(health.available)
    #expect(health.osOK)
    #expect(health.versionOK)
    #expect(health.imageDigestOK)  // host inspect .configuration.image.descriptor.digest
    #expect(health.capsEmpty)  // in-guest CapEff == 0000000000000000
    #expect(health.netIsolated)  // in-guest loopback-only, outbound probe fails
    #expect(health.capsMatch)  // host inspect cpus == 2, memoryInBytes == 512 MiB
    #expect(health.reaperOK)  // in-guest /proc/1/comm is the init reaper
    #expect(health.rootfsRO)  // in-guest EROFS outside /tmp, writes under /work fail
    #expect(health.stagingRO)
    #expect(health.interpretersOK)  // /usr/bin/python and /bin/sh both present
    #expect(health.lastError == nil)
    await backend.shutdown()
  }

  @Test func cleanupLeavesNoOwnedContainerAfterSuccessTimeoutAndCancellation() async throws {
    // given
    let host = try RealSandboxHost()
    defer { host.remove() }
    let backend = try await host.readyBackend()
    defer { Task { await backend.shutdown() } }

    // when/then — success
    _ = await backend.run(host.shellRequest("true"))
    #expect(try await host.ownedNames(backend).isEmpty)

    // when/then — timeout
    _ = await backend.run(host.shellRequest("sleep 600", timeout: .seconds(2)))
    #expect(try await host.ownedNames(backend).isEmpty)

    // when/then — cancellation while the guest is actually running (gate on real state, no sleeps)
    let running = Task { await backend.run(host.shellRequest("sleep 600", timeout: .seconds(60))) }
    let appeared = await host.pollUntilTrue(timeout: .seconds(30)) {
      (await backend.ownedContainerNamesForTesting())?.isEmpty == false
    }
    #expect(appeared)
    running.cancel()
    let cancelled = await running.value
    #expect(cancelled.terminationReason == .cancelled)
    #expect(try await host.ownedNames(backend).isEmpty)
  }

  @Test func bootReapRemovesADeliberatelyOrphanedOwnedInstance() async throws {
    // given — a ready backend and a hand-launched owned orphan the backend never tracked
    let host = try RealSandboxHost()
    defer { host.remove() }
    let backend = try await host.readyBackend()
    defer { Task { await backend.shutdown() } }
    let initImage = try #require(await backend.preparedInitImageForTesting)
    let runner = SwiftSubprocessContainerCommandRunner()
    let identity = ExecutionIdentity()
    let orphanScratch = host.root.appendingPathComponent("orphan-scratch", isDirectory: true)
    try FileManager.default.createDirectory(at: orphanScratch, withIntermediateDirectories: true)

    // when — launch a detached owned container that outlives the launching call
    let launch = await runner.run(
      ContainerCommand(
        arguments: ContainerInvocation.detachedCanary(
          identity: identity,
          scratchPath: orphanScratch.path,
          settings: host.settings,
          initImage: initImage
        ),
        timeout: .seconds(30),
        captureLimit: ContainerBackend.maxControlStreamBytes,
        teardownGracePeriod: .seconds(2)
      )
    )
    guard case .exited(0) = launch.termination else {
      Issue.record("failed to launch the deliberate orphan")
      return
    }

    // then — the reaper sees it by prefix+label and removes it
    #expect(try await host.ownedNames(backend).contains(identity.name))
    #expect(await backend.reapOwnedContainersForTesting())
    #expect(!(try await host.ownedNames(backend)).contains(identity.name))
  }
}

// MARK: - Real Host Fixture

private struct RealSandboxHost {
  let root: URL
  let settings: ExecSandboxSettings

  init(memoryMiB: Int = 1024, cpus: Int = 4) throws {
    let image = try #require(
      ProcessInfo.processInfo.environment["CLAW_EXEC_IMAGE"].flatMap(PinnedImageReference.parse),
      "CLAW_EXEC_IMAGE must be a digest-pinned reference for Layer B"
    )
    self.settings = ExecSandboxSettings(workloadImage: image, memoryMiB: memoryMiB, cpus: cpus)
    self.root = FileManager.default.temporaryDirectory
      .appendingPathComponent("claw-exec-layerb-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func backend(memoryMiB: Int? = nil, cpus: Int? = nil) -> ContainerBackend {
    let resolved =
      memoryMiB == nil && cpus == nil
      ? settings
      : ExecSandboxSettings(
        workloadImage: settings.workloadImage,
        memoryMiB: memoryMiB ?? settings.memoryMiB,
        cpus: cpus ?? settings.cpus
      )
    return ContainerBackend(
      settings: resolved,
      stateRoot: root,
      commands: SwiftSubprocessContainerCommandRunner(),
      sanitizeReason: { $0 }
    )
  }

  func readyBackend() async throws -> ContainerBackend {
    let backend = backend()
    let health = await backend.prepare()
    try #require(
      health.isReady,
      "sandbox canary must pass before Layer B runs: \(health.lastError ?? "unknown")"
    )
    return backend
  }

  func shellRequest(
    _ script: String,
    network: Bool = false,
    timeout: Duration = .seconds(30),
    inputs: [StagedFile] = []
  ) -> ExecutionRequest {
    ExecutionRequest(
      language: .sh,
      entrypoint: StagedFile(
        name: ".clawd-entrypoint.sh",
        bytes: Data(script.utf8),
        mode: .readExecute
      ),
      inputs: inputs,
      network: network,
      timeout: timeout
    )
  }

  // A nil result means the owned-container inspection itself failed; that is a Layer-B failure,
  // never a silent "empty".
  func ownedNames(_ backend: ContainerBackend) async throws -> [String] {
    try #require(
      await backend.ownedContainerNamesForTesting(),
      "owned-container inspection failed"
    )
  }

  func pollUntilTrue(timeout: Duration, _ predicate: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if await predicate() { return true }
      await Task.yield()
    }
    return false
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
