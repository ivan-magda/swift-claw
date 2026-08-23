import ClawCore
import ClawProcess
import Foundation
import Testing

@testable import ClawExec

@Suite struct ContainerInvocationTests {
  @Test func semanticVersionAcceptsExactlyThreeNumericComponents() {
    // given
    let valid = ["0.0.0", "1.0.0", "12.34.56"]
    let invalid = ["", "1", "1.2", "1.2.3.4", "v1.2.3", "1.2.3-beta", "1.-2.3", "١.٢.٣"]

    // when
    let parsed = valid.compactMap(SemanticVersion.init)

    // then
    #expect(
      parsed == [SemanticVersion(0, 0, 0), SemanticVersion(1, 0, 0), SemanticVersion(12, 34, 56)]
    )
    #expect(invalid.allSatisfy { SemanticVersion($0) == nil })
  }

  @Test func semanticVersionUsesLexicographicNumericOrdering() {
    // given
    let versions = [
      SemanticVersion(2, 0, 0),
      SemanticVersion(1, 10, 0),
      SemanticVersion(1, 2, 10),
      SemanticVersion(1, 2, 3),
    ]

    // when
    let sorted = versions.sorted()

    // then
    #expect(
      sorted == [
        SemanticVersion(1, 2, 3),
        SemanticVersion(1, 2, 10),
        SemanticVersion(1, 10, 0),
        SemanticVersion(2, 0, 0),
      ]
    )
  }

  @Test func settingsKeepOnePinnedAuthority() throws {
    // given
    let image = try #require(
      PinnedImageReference.parse(
        "cgr.dev/swift-claw/python@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      )
    )

    // when
    let settings = ExecSandboxSettings(workloadImage: image, memoryMiB: 1024, cpus: 4)

    // then
    #expect(settings.workloadImage == image)
    #expect(settings.memoryMiB == 1024)
    #expect(settings.cpus == 4)
    #expect(ExecSandboxSettings.minimumContainerVersion == SemanticVersion(1, 0, 0))
    #expect(ExecSandboxSettings.pythonInterpreter == "/usr/bin/python")
    #expect(ExecSandboxSettings.shellInterpreter == "/bin/sh")
    #expect(ExecSandboxSettings.platform == "linux/arm64")
  }

  @Test func commandResultCarriesRawPrefixesAndTypedTermination() {
    // given
    let output = CapturedCommandStream(
      bytes: Data([0x66, 0x6f, 0x6f]),
      totalBytes: 9,
      truncated: true
    )
    let command = LocalCommand(
      arguments: ["system", "status"],
      timeout: .seconds(5),
      captureLimit: 1024,
      teardownGracePeriod: .seconds(2)
    )

    // when
    let result = LocalCommandResult(
      termination: .exited(7),
      stdout: output,
      stderr: CapturedCommandStream(bytes: Data(), totalBytes: 0, truncated: false),
      processIdentifier: 42
    )

    // then
    #expect(command.arguments == ["system", "status"])
    #expect(command.teardownGracePeriod == .seconds(2))
    #expect(result.termination == .exited(7))
    #expect(result.stdout == output)
    #expect(result.processIdentifier == 42)
  }

  @Test func identityUsesDeterministicLowercaseUUIDName() throws {
    // given
    let uuid = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))

    // when
    let identity = ExecutionIdentity(uuid: uuid)

    // then
    #expect(identity.identifier == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    #expect(identity.name == "clawd-exec-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
  }

  private func makeIdentity() throws -> ExecutionIdentity {
    ExecutionIdentity(
      uuid: try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
    )
  }

  private func makeSettings() throws -> ExecSandboxSettings {
    ExecSandboxSettings(
      workloadImage: try #require(
        PinnedImageReference.parse(
          "cgr.dev/swift-claw/python@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        )
      ),
      memoryMiB: 1024,
      cpus: 4
    )
  }

  @Test func noEgressRunArgvIsExactAndFullyExplicit() throws {
    // given / when
    let arguments = ContainerInvocation.run(
      context: ContainerLaunchContext(
        identity: try makeIdentity(),
        scratchPath: "/state/exec-scratch/11111111-2222-3333-4444-555555555555",
        settings: try makeSettings(),
        initImage: "ghcr.io/apple/containerization/vminit:1.1.0"
      ),
      cidFilePath: "/state/exec-control/11111111-2222-3333-4444-555555555555.cid",
      language: .python,
      network: false
    )

    // then
    #expect(
      arguments == [
        "run", "--scheme", "https", "--progress", "none", "--platform", "linux/arm64",
        "--rm", "--name", "clawd-exec-11111111-2222-3333-4444-555555555555",
        "--label", "clawd.exec=1", "--cidfile",
        "/state/exec-control/11111111-2222-3333-4444-555555555555.cid",
        "--cap-drop", "ALL", "--init", "--init-image",
        "ghcr.io/apple/containerization/vminit:1.1.0", "--read-only", "--tmpfs", "/tmp",
        "--cpus", "4", "--memory", "1024M", "--mount",
        "type=bind,source=/state/exec-scratch/11111111-2222-3333-4444-555555555555,target=/work,readonly",
        "--network", "none", "--no-dns", "--entrypoint", "/usr/bin/python",
        "cgr.dev/swift-claw/python@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "/work/.clawd-entrypoint.py",
      ]
    )
  }

  @Test func optedInEgressRunArgvIsExactAndHasNoNoDNSFlag() throws {
    // given / when
    let arguments = ContainerInvocation.run(
      context: ContainerLaunchContext(
        identity: try makeIdentity(),
        scratchPath: "/scratch",
        settings: try makeSettings(),
        initImage: "ghcr.io/apple/containerization/vminit:1.1.0"
      ),
      cidFilePath: "/control/run.cid",
      language: .sh,
      network: true
    )

    // then
    #expect(arguments.containsSubsequence(["--network", "default"]))
    #expect(!arguments.contains("--no-dns"))
    #expect(arguments.containsSubsequence(["--entrypoint", "/bin/sh"]))
    #expect(arguments.last == "/work/.clawd-entrypoint.sh")
  }

  @Test func runArgvCannotEmitForbiddenExposureFlagsOrAmbientMounts() throws {
    // given
    let arguments = ContainerInvocation.run(
      context: ContainerLaunchContext(
        identity: try makeIdentity(),
        scratchPath: "/approved-scratch",
        settings: try makeSettings(),
        initImage: "ghcr.io/apple/containerization/vminit:1.1.0"
      ),
      cidFilePath: "/control/run.cid",
      language: .python,
      network: false
    )
    let forbidden = ["--cap-add", "--volume", "-v", "--publish", "-p", "--ssh"]

    // when
    let joined = arguments.joined(separator: " ")

    // then
    #expect(forbidden.allSatisfy { !arguments.contains($0) })
    #expect(!joined.contains(FileManager.default.homeDirectoryForCurrentUser.path))
    #expect(arguments.filter { $0 == "--mount" }.count == 1)
    #expect(arguments.contains("type=bind,source=/approved-scratch,target=/work,readonly"))
    #expect(arguments.containsSubsequence(["--scheme", "https"]))
    #expect(arguments.containsSubsequence(["--progress", "none"]))
    #expect(arguments.containsSubsequence(["--platform", "linux/arm64"]))
  }

  @Test func detachedCanaryUsesTheSameHardeningAuthority() throws {
    // given
    let settings = try makeSettings()

    // when
    let arguments = ContainerInvocation.detachedCanary(
      context: ContainerLaunchContext(
        identity: try makeIdentity(),
        scratchPath: "/canary",
        settings: settings,
        initImage: "ghcr.io/apple/containerization/vminit:1.1.0"
      )
    )

    // then
    #expect(arguments.contains("--detach"))
    #expect(arguments.containsSubsequence(["--network", "none", "--no-dns"]))
    #expect(
      arguments.containsSubsequence(["--init-image", "ghcr.io/apple/containerization/vminit:1.1.0"])
    )
    #expect(arguments.containsSubsequence(["--entrypoint", "/usr/bin/python"]))
    #expect(
      arguments.suffix(3) == [
        settings.workloadImage.description,
        "-c",
        "import signal; signal.pause()",
      ]
    )
  }

  @Test func controlInvocationsAreExact() {
    // given / when / then
    #expect(ContainerInvocation.systemStatus() == ["system", "status", "--format", "json"])
    #expect(ContainerInvocation.systemVersion() == ["system", "version", "--format", "json"])
    #expect(
      ContainerInvocation.systemPropertyList()
        == ["system", "property", "list", "--format", "json"]
    )
    #expect(ContainerInvocation.listAll() == ["list", "--all", "--format", "json"])
    #expect(ContainerInvocation.inspect("owned") == ["inspect", "owned"])
    #expect(ContainerInvocation.inspectImage("image") == ["image", "inspect", "image"])
    #expect(
      ContainerInvocation.execCanary("owned", script: "probe")
        == ["exec", "--user", "0", "owned", "/bin/sh", "-c", "probe"]
    )
    #expect(
      ContainerInvocation.pull("registry/repo:tag")
        == ["image", "pull", "--scheme", "https", "--progress", "none", "registry/repo:tag"]
    )
    #expect(ContainerInvocation.stop("owned") == ["stop", "--time", "1", "owned"])
    #expect(ContainerInvocation.kill("owned") == ["kill", "--signal", "KILL", "owned"])
    #expect(ContainerInvocation.remove("owned") == ["rm", "--force", "owned"])
  }
}

extension Array where Element: Equatable {
  fileprivate func containsSubsequence(_ subsequence: [Element]) -> Bool {
    guard !subsequence.isEmpty, subsequence.count <= count else { return false }
    return indices.dropLast(subsequence.count - 1).contains { index in
      Array(self[index..<(index + subsequence.count)]) == subsequence
    }
  }
}
