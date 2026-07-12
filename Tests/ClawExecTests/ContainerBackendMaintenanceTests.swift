import ClawCore
import Foundation
import Testing

@testable import ClawExec

@Suite struct ContainerBackendMaintenanceTests {
  @Test func prepareReapsPullsExactImagesAndPassesHardenedCanary() async throws {
    // given
    let fixture = try MaintenanceFixture()
    defer { fixture.remove() }
    let runner = MaintenanceCommandRunner { command, history in
      fixture.response(for: command, history: history)
    }
    let backend = fixture.backend(commands: runner)

    // when
    let health = await backend.prepare()

    // then
    #expect(health.isReady)
    #expect(health.engineVersion == "1.1.0")
    #expect(
      await backend.preparedInitImageForTesting
        == "ghcr.io/apple/containerization/vminit:1.1.0"
    )
    let arguments = await runner.recorded().map(\.arguments)
    #expect(
      arguments.contains(ContainerInvocation.pull(fixture.settings.workloadImage.description))
    )
    #expect(
      arguments.contains(
        ContainerInvocation.pull("ghcr.io/apple/containerization/vminit:1.1.0")
      )
    )
    #expect(
      !arguments.contains(
        ContainerInvocation.inspectImage("ghcr.io/apple/containerization/vminit:1.1.0")
      )
    )
    #expect(
      arguments.contains(
        ContainerInvocation.inspectImage(fixture.settings.workloadImage.description)
      )
    )
    #expect(arguments.contains { $0.first == "run" && $0.contains("--detach") })
    #expect(arguments.contains { $0.first == "exec" && $0.contains("--user") })
  }

  @Test func prepareRejectsUnqualifiedRuntimeInitImageBeforePullOrCanary() async throws {
    // given
    let fixture = try MaintenanceFixture(initImage: "vminit:latest")
    defer { fixture.remove() }
    let runner = MaintenanceCommandRunner { command, history in
      fixture.response(for: command, history: history)
    }
    let backend = fixture.backend(commands: runner)

    // when
    let health = await backend.prepare()

    // then
    #expect(!health.isReady)
    #expect(health.lastError == "container runtime init image is not a registry-qualified tag")
    #expect(await backend.preparedInitImageForTesting == nil)
    let arguments = await runner.recorded().map(\.arguments)
    #expect(!arguments.contains { $0.starts(with: ["image", "pull"]) })
    #expect(!arguments.contains { $0.first == "run" })
  }

  @Test func reaperRequiresBothOwnedPrefixAndLabel() async throws {
    // given
    let fixture = try MaintenanceFixture()
    defer { fixture.remove() }
    let owned = "clawd-exec-11111111-2222-3333-4444-555555555555"
    let prefixOnly = "clawd-exec-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    let labelOnly = "someone-elses-container"
    let firstList = """
      [
        {"id":"\(owned)","configuration":{"id":"\(owned)","labels":{"clawd.exec":"1"}}},
        {"id":"\(prefixOnly)","configuration":{"id":"\(prefixOnly)","labels":{}}},
        {"id":"\(labelOnly)","configuration":{"id":"\(labelOnly)","labels":{"clawd.exec":"1"}}}
      ]
      """
    let finalList = """
      [
        {"id":"\(prefixOnly)","configuration":{"id":"\(prefixOnly)","labels":{}}},
        {"id":"\(labelOnly)","configuration":{"id":"\(labelOnly)","labels":{"clawd.exec":"1"}}}
      ]
      """
    let runner = MaintenanceCommandRunner { command, history in
      if command.arguments == ContainerInvocation.listAll() {
        return maintenanceJSON(history.count == 1 ? firstList : finalList)
      }
      return maintenanceResult(.exited(0))
    }
    let backend = fixture.backend(commands: runner)

    // when
    let reaped = await backend.reapOwnedContainersForTesting()

    // then
    #expect(reaped)
    let arguments = await runner.recorded().map(\.arguments)
    #expect(arguments.contains(ContainerInvocation.stop(owned)))
    #expect(arguments.contains(ContainerInvocation.kill(owned)))
    #expect(arguments.contains(ContainerInvocation.remove(owned)))
    #expect(!arguments.contains(ContainerInvocation.remove(prefixOnly)))
    #expect(!arguments.contains(ContainerInvocation.remove(labelOnly)))
  }

  @Test func workloadDigestMismatchFailsBeforeCanary() async throws {
    // given
    let fixture = try MaintenanceFixture(
      inspectedDigest: "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    )
    defer { fixture.remove() }
    let runner = MaintenanceCommandRunner { command, history in
      fixture.response(for: command, history: history)
    }
    let backend = fixture.backend(commands: runner)

    // when
    let health = await backend.prepare()

    // then
    #expect(!health.imageDigestOK)
    #expect(!health.isReady)
    #expect(await backend.preparedInitImageForTesting == nil)
    #expect(!(await runner.recorded()).contains { $0.arguments.first == "run" })
  }

  @Test func canaryReportsEachGuestAndHostHardeningBit() async throws {
    // given
    let fixture = try MaintenanceFixture(
      guestProbe: GuestProbeFixture(
        capsEmpty: true,
        netIsolated: false,
        reaperOK: true,
        rootfsRO: true,
        stagingRO: true,
        interpretersOK: true
      )
    )
    defer { fixture.remove() }
    let runner = MaintenanceCommandRunner { command, history in
      fixture.response(for: command, history: history)
    }
    let backend = fixture.backend(commands: runner)

    // when
    let health = await backend.prepare()

    // then
    #expect(health.available)
    #expect(health.imageDigestOK)
    #expect(health.capsEmpty)
    #expect(!health.netIsolated)
    #expect(health.capsMatch)
    #expect(health.reaperOK)
    #expect(health.rootfsRO)
    #expect(health.stagingRO)
    #expect(health.interpretersOK)
    #expect(!health.isReady)
    #expect(health.lastError == "sandbox canary hardening check failed")
    #expect(await backend.preparedInitImageForTesting == nil)
  }

  @Test func truncatedPropertyOrInspectJSONFailsClosed() async throws {
    // given
    let fixture = try MaintenanceFixture()
    defer { fixture.remove() }
    let runner = MaintenanceCommandRunner { command, history in
      if command.arguments == ContainerInvocation.systemPropertyList() {
        return maintenanceResult(
          .exited(0),
          stdout: Data(#"{"vminit":{"image":"ghcr.io/apple/containerization/vminit:1.1.0"}}"#.utf8),
          stdoutTotal: 2_000_000,
          stdoutTruncated: true
        )
      }
      return fixture.response(for: command, history: history)
    }
    let backend = fixture.backend(commands: runner)

    // when
    let health = await backend.prepare()

    // then
    #expect(!health.isReady)
    #expect(health.lastError == "could not read container runtime properties")
  }

  @Test func prepareRefusesWithoutIssuingCommandsWhileAnExecutionIsInFlight() async throws {
    // given
    let fixture = try MaintenanceFixture()
    defer { fixture.remove() }
    let runner = MaintenanceCommandRunner { command, _ in
      if command.arguments.first == "run" && !command.arguments.contains("--detach") {
        maintenanceWriteCidfile(command.arguments)
        while !Task.isCancelled { await Task.yield() }
        return maintenanceResult(.cancelled)
      }
      return command.arguments == ContainerInvocation.listAll()
        ? maintenanceJSON("[]")
        : maintenanceResult(.exited(0))
    }
    let backend = fixture.backend(commands: runner)
    await backend.setPreparedInitImageForTesting(fixture.initImage)
    let run = Task { await backend.run(maintenanceRequest()) }
    await runner.waitForCount(1)
    let commandsBeforePrepare = await runner.recorded().count

    // when
    let health = await backend.prepare()

    // then
    #expect(!health.isReady)
    #expect(health.lastError == "sandbox prepare refused: executions in flight")
    #expect(await runner.recorded().count == commandsBeforePrepare)
    run.cancel()
    _ = await run.value
  }

  @Test func shutdownCancelsRunningWorkThenReapsAndSweeps() async throws {
    // given
    let fixture = try MaintenanceFixture()
    defer { fixture.remove() }
    let runner = MaintenanceCommandRunner { command, _ in
      if command.arguments.first == "run" && !command.arguments.contains("--detach") {
        maintenanceWriteCidfile(command.arguments)
        while !Task.isCancelled { await Task.yield() }
        return maintenanceResult(.cancelled)
      }
      return command.arguments == ContainerInvocation.listAll()
        ? maintenanceJSON("[]")
        : maintenanceResult(.exited(0))
    }
    let backend = fixture.backend(commands: runner)
    await backend.setPreparedInitImageForTesting(fixture.initImage)
    let run = Task { await backend.run(maintenanceRequest()) }
    await runner.waitForCount(1)

    // when
    await backend.shutdown()
    let result = await run.value
    await backend.shutdown()

    // then
    #expect(result.terminationReason == .cancelled)
    #expect(await backend.preparedInitImageForTesting == nil)
    #expect(try maintenanceScratchChildren(fixture.root).isEmpty)
    #expect((await runner.recorded()).contains { $0.arguments == ContainerInvocation.listAll() })
  }
}

private struct GuestProbeFixture: Sendable {
  let capsEmpty: Bool
  let netIsolated: Bool
  let reaperOK: Bool
  let rootfsRO: Bool
  let stagingRO: Bool
  let interpretersOK: Bool

  static let passing = GuestProbeFixture(
    capsEmpty: true,
    netIsolated: true,
    reaperOK: true,
    rootfsRO: true,
    stagingRO: true,
    interpretersOK: true
  )

  var json: String {
    """
    {"capsEmpty":\(capsEmpty),"netIsolated":\(netIsolated),"reaperOK":\(reaperOK),"rootfsRO":\(rootfsRO),"stagingRO":\(stagingRO),"interpretersOK":\(interpretersOK)}
    """
  }
}

private final class MaintenanceFixture: @unchecked Sendable {
  let root: URL
  let settings: ExecSandboxSettings
  let initImage: String
  let inspectedDigest: String
  let guestProbe: GuestProbeFixture

  init(
    initImage: String = "ghcr.io/apple/containerization/vminit:1.1.0",
    inspectedDigest: String =
      "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    guestProbe: GuestProbeFixture = .passing
  ) throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "clawd-maintenance-tests-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    guard
      let workloadImage = PinnedImageReference.parse(
        "cgr.dev/swift-claw/python@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      )
    else { throw MaintenanceFixtureError.missingIdentity }
    settings = ExecSandboxSettings(
      workloadImage: workloadImage,
      memoryMiB: 1024,
      cpus: 4
    )
    self.initImage = initImage
    self.inspectedDigest = inspectedDigest
    self.guestProbe = guestProbe
  }

  func backend(commands: any ContainerCommandRunning) -> ContainerBackend {
    ContainerBackend(
      settings: settings,
      stateRoot: root,
      commands: commands,
      sanitizeReason: { $0 },
      now: { ContinuousClock.now },
      supportedHost: { true }
    )
  }

  func response(
    for command: ContainerCommand,
    history: [ContainerCommand]
  ) -> ContainerCommandResult {
    let arguments = command.arguments
    if arguments == ContainerInvocation.systemStatus() {
      return maintenanceJSON(#"{"status":"running"}"#)
    }
    if arguments == ContainerInvocation.systemVersion() {
      return maintenanceJSON(
        #"[{"version":"1.1.0","buildType":"release","commit":"5973b9c","appName":"container"}]"#
      )
    }
    if arguments == ContainerInvocation.listAll() {
      return maintenanceJSON("[]")
    }
    if arguments == ContainerInvocation.systemPropertyList() {
      return maintenanceJSON("{\"vminit\":{\"image\":\"\(initImage)\"}}")
    }
    if arguments == ContainerInvocation.inspectImage(settings.workloadImage.description) {
      return maintenanceJSON(
        """
        [{"configuration":{"name":"\(settings.workloadImage.description)","descriptor":{"digest":"\(inspectedDigest)"}}}]
        """
      )
    }
    if arguments.first == "run" && arguments.contains("--detach") {
      return maintenanceResult(.exited(0), stdout: Data("canary-name".utf8))
    }
    if arguments.first == "inspect" {
      let name = arguments[1]
      return maintenanceJSON(
        """
        [{"configuration":{"id":"\(name)","image":{"reference":"\(settings.workloadImage.description)","descriptor":{"digest":"\(inspectedDigest)"}},"labels":{"clawd.exec":"1"},"resources":{"cpus":4,"memoryInBytes":1073741824},"readOnly":true,"useInit":true,"capAdd":[],"capDrop":["ALL"]},"status":{"state":"running"}}]
        """
      )
    }
    if arguments.first == "exec" {
      return maintenanceJSON(guestProbe.json)
    }
    _ = history
    return maintenanceResult(.exited(0))
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private actor MaintenanceCommandRunner: ContainerCommandRunning {
  typealias Handler =
    @Sendable (ContainerCommand, [ContainerCommand]) async -> ContainerCommandResult

  private let handler: Handler
  private var commands: [ContainerCommand] = []
  private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

  init(handler: @escaping Handler) {
    self.handler = handler
  }

  func run(_ command: ContainerCommand) async -> ContainerCommandResult {
    commands.append(command)
    let history = commands
    let ready = waiters.filter { history.count >= $0.0 }
    waiters.removeAll { history.count >= $0.0 }
    for waiter in ready { waiter.1.resume() }
    return await handler(command, history)
  }

  func recorded() -> [ContainerCommand] { commands }

  func waitForCount(_ count: Int) async {
    if commands.count >= count { return }
    await withCheckedContinuation { continuation in waiters.append((count, continuation)) }
  }
}

private func maintenanceResult(
  _ termination: ContainerCommandTermination,
  stdout: Data = Data(),
  stdoutTotal: Int? = nil,
  stdoutTruncated: Bool = false
) -> ContainerCommandResult {
  ContainerCommandResult(
    termination: termination,
    stdout: CapturedCommandStream(
      bytes: stdout,
      totalBytes: stdoutTotal ?? stdout.count,
      truncated: stdoutTruncated
    ),
    stderr: CapturedCommandStream(bytes: Data(), totalBytes: 0, truncated: false),
    processIdentifier: 42,
    wallClock: .milliseconds(1)
  )
}

private func maintenanceJSON(_ json: String) -> ContainerCommandResult {
  maintenanceResult(.exited(0), stdout: Data(json.utf8))
}

private func maintenanceRequest() -> ExecutionRequest {
  ExecutionRequest(
    language: .python,
    entrypoint: StagedFile(
      name: ".clawd-entrypoint.py",
      bytes: Data("print('ok')".utf8),
      mode: .readExecute
    ),
    inputs: [],
    network: false,
    timeout: .seconds(30)
  )
}

private func maintenanceWriteCidfile(_ arguments: [String]) {
  guard
    let pathIndex = arguments.firstIndex(of: "--cidfile"),
    let nameIndex = arguments.firstIndex(of: "--name"),
    (try? Data(arguments[nameIndex + 1].utf8).write(
      to: URL(fileURLWithPath: arguments[pathIndex + 1]),
      options: .withoutOverwriting
    )) != nil
  else {
    preconditionFailure("run invocation did not carry cidfile identity")
  }
}

private func maintenanceScratchChildren(_ stateRoot: URL) throws -> [URL] {
  let root = stateRoot.appending(path: "exec-scratch")
  guard FileManager.default.fileExists(atPath: root.path) else { return [] }
  return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
}

private enum MaintenanceFixtureError: Error {
  case missingIdentity
}
